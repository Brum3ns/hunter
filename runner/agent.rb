require "net/http"
require "json"
require "uri"
require_relative "curl_command"

# Minimal pull loop: claim a curl job, execute it in this hardened container,
# post the result back. Outbound HTTP only; never opens a listening socket.
API   = ENV.fetch("HUNTER_API_URL", "http://web:5000")
TOKEN = ENV.fetch("RUNNER_TOKEN")
POLL  = Float(ENV.fetch("RUNNER_POLL_INTERVAL", "2"))
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

def submit(id, result)
  post("/api/v1/runner/jobs/#{id}/result", {
    exit_status: result.exit_status,
    stdout: result.stdout,
    stderr: result.stderr,
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
    submit(job["id"], result)
  rescue => e
    warn "runner error: #{e.class}: #{e.message}"
    sleep POLL * 3
  end
end
