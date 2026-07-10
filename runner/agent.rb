require "net/http"
require "json"
require "uri"
require_relative "curl_command"
require_relative "token"

# Concurrent pull loop: several worker threads each claim a curl job, execute it
# in this hardened container, and post the result back. Both curl and the result
# POST are blocking I/O, so a single worker sits idle on the network while one
# request is in flight and every other job waits behind it. Running a pool lets
# independent jobs overlap instead of queueing behind one slow request.
#
# Safe to parallelize: the server-side claim is an atomic
# `FOR UPDATE SKIP LOCKED` dequeue, so two workers never claim the same job, and
# the work is I/O-bound, so Ruby releases the GIL during curl and the POST.
# Outbound HTTP only; never opens a listening socket.
class RunnerAgent
  def initialize(api:, token:, poll:, max_time:, max_output:, concurrency:)
    @api = api
    @token = token
    @poll = poll
    @max_time = max_time
    @max_output = max_output
    @concurrency = concurrency
  end

  def self.from_env
    new(
      api: ENV.fetch("HUNTER_API_URL", "http://web:5000"),
      token: RunnerToken.normalize(ENV["RUNNER_TOKEN"]),
      poll: Float(ENV.fetch("RUNNER_POLL_INTERVAL", "2")),
      max_time: Integer(ENV.fetch("CURL_MAX_TIME", "30")),
      max_output: Integer(ENV.fetch("CURL_MAX_OUTPUT", "262144")),
      concurrency: Integer(ENV.fetch("RUNNER_MAX_CONCURRENCY", "30"))
    )
  end

  attr_reader :api, :token, :poll, :concurrency

  # Spawn the worker pool and block until every worker stops. `stop` is polled by
  # each worker between jobs; the default never stops, so the pool runs forever.
  def run(stop: -> { false })
    Array.new(@concurrency) { |i| Thread.new { work_loop(i, stop) } }.each(&:join)
  end

  def work_loop(index, stop)
    until stop.call
      begin
        # No job available: back off before polling again, with jitter so idle
        # workers don't all hit the claim endpoint in lockstep.
        sleep(@poll + rand * @poll) unless handle_one
      rescue => e
        warn "runner worker #{index} error: #{e.class}: #{e.message}"
        sleep @poll * 3
      end
    end
  end

  # Claim and process a single job. Returns true if a job ran, false if the queue
  # was empty. Public so the pool can be exercised deterministically in tests.
  def handle_one
    job = claim
    return false if job.nil?

    result = execute_job(job["command"])
    res = submit(job["id"], result)
    warn "submit failed for job #{job["id"]}: HTTP #{res.code}" unless res.code.start_with?("2")
    true
  end

  def claim
    res = post("/api/v1/runner/jobs/claim")
    return nil if res.code == "204"
    raise "claim failed: #{res.code}" unless res.code == "200"

    JSON.parse(res.body)
  end

  def execute_job(command)
    Sandbox::CurlCommand.execute(command, max_time: @max_time, max_output: @max_output)
  end

  def submit(id, result)
    post("/api/v1/runner/jobs/#{id}/result", {
      exit_status: result.exit_status,
      stdout: utf8(result.stdout),
      stderr: utf8(result.stderr),
      error: result.error,
      duration_ms: result.duration_ms,
      output_truncated: result.output_truncated
    })
  end

  private

  def post(path, body = nil)
    uri = URI.join(@api, path)
    req = Net::HTTP::Post.new(uri)
    req["Authorization"] = "Bearer #{@token}"
    if body
      req["Content-Type"] = "application/json"
      req.body = body.to_json
    end
    Net::HTTP.start(uri.host, uri.port, open_timeout: 10, read_timeout: 30) { |h| h.request(req) }
  end

  # curl output is captured in binary mode, so it may hold non-UTF-8 bytes (gzip,
  # images, truncated multibyte). Scrub to valid UTF-8 so JSON serialization and
  # the Postgres text columns never choke and drop an otherwise-complete result.
  def utf8(str)
    str.to_s.dup.force_encoding("UTF-8").scrub("�")
  end
end

if $PROGRAM_NAME == __FILE__
  agent = RunnerAgent.from_env

  # Without a token every claim just 401s forever and no job is ever run, so fail
  # loudly at startup instead of looping silently. Mint one with
  # `bin/rails runners:create NAME=curl-runner KINDS=curl` and set RUNNER_TOKEN.
  if agent.token.empty?
    abort "RUNNER_TOKEN is not set — mint one with `bin/rails runners:create` and put it in .env"
  end

  puts "runner agent starting; polling #{agent.api} every #{agent.poll}s with #{agent.concurrency} workers"
  agent.run
end
