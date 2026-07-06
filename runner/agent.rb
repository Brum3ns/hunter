require "net/http"
require "json"
require "uri"
require_relative "curl_command"

# Minimal pull loop: claim a curl job, execute it in this hardened container,
# post the result back. Outbound HTTP only; never opens a listening socket.
API   = ENV.fetch("HUNTER_API_URL", "http://web:5000")
TOKEN = ENV.fetch("RUNNER_TOKEN", "").strip
POLL  = Float(ENV.fetch("RUNNER_POLL_INTERVAL", "2"))

# Without a token every claim just 401s forever and no job is ever run, so fail
# loudly at startup instead of looping silently. Mint one with
# `bin/rails runners:create NAME=curl-runner KINDS=curl` and set RUNNER_TOKEN.
if TOKEN.empty?
  abort "RUNNER_TOKEN is not set — mint one with `bin/rails runners:create` and put it in .env"
end
MAX_TIME   = Integer(ENV.fetch("CURL_MAX_TIME", "30"))
MAX_OUTPUT = Integer(ENV.fetch("CURL_MAX_OUTPUT", "262144"))

def post(path, body = nil)
  uri = URI.join(API, path)
  req = Net::HTTP::Post.new(uri)
  req["Authorization"] = "Bearer #{TOKEN}"
  if body
    req["Content-Type"] = "application/json"
    req.body = body.to_json
  end
  Net::HTTP.start(uri.host, uri.port, open_timeout: 10, read_timeout: 30) { |h| h.request(req) }
end

def claim
  res = post("/api/v1/runner/jobs/claim")
  return nil if res.code == "204"
  raise "claim failed: #{res.code}" unless res.code == "200"

  JSON.parse(res.body)
end

# curl output is captured in binary mode, so it may hold non-UTF-8 bytes (gzip,
# images, truncated multibyte). Scrub to valid UTF-8 so JSON serialization and
# the Postgres text columns never choke and drop an otherwise-complete result.
def utf8(str)
  str.to_s.dup.force_encoding("UTF-8").scrub("�")
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

puts "runner agent starting; polling #{API} every #{POLL}s"
loop do
  begin
    job = claim
    if job.nil?
      sleep POLL
      next
    end
    result = Sandbox::CurlCommand.execute(job["command"], max_time: MAX_TIME, max_output: MAX_OUTPUT)
    res = submit(job["id"], result)
    warn "submit failed for job #{job["id"]}: HTTP #{res.code}" unless res.code.start_with?("2")
  rescue => e
    warn "runner error: #{e.class}: #{e.message}"
    sleep POLL * 3
  end
end
