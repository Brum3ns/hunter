require "net/http"

module Assistant
  # Boot-time reachability check for the two services Rails calls over HTTP.
  #
  # It exists because every failure in this path used to surface only in the chat
  # UI, as one opaque code, after a user had already sent a message. Running it
  # during `db:seed` — which Compose executes before the web server starts — means
  # `docker compose up` output itself says whether the Assistant will work.
  #
  # Advisory only. It never raises and never changes state: Compose runs
  # `db:seed && foreman start`, so anything that can abort the seed stops the web
  # server from booting, and an unreachable gateway must never do that.
  module Preflight
    Check = Data.define(:service, :url, :ok, :detail)

    # The gateway and validator have no `depends_on`, so they boot in parallel with
    # web. A single probe would race them; this retries briefly before reporting.
    ATTEMPTS = 10
    SLEEP_SECONDS = 2
    TIMEOUT_SECONDS = 2

    module_function

    def call(prober: method(:probe), sleeper: method(:sleep))
      [
        { service: "assistant-gateway", url: healthz(GatewayClient.endpoint) },
        { service: "assistant-validator", url: healthz(ValidatorClient.endpoint) }
      ].map { |target| await(target, prober: prober, sleeper: sleeper) }
    end

    # Turns ".../turns" into ".../healthz": /healthz needs no bearer token, so this
    # reports transport reachability without depending on the ingress secret being
    # correct. A wrong token is a different fault, reported by its own error code.
    def healthz(endpoint)
      URI.join(endpoint, "/healthz").to_s
    end

    # The rescue is deliberately here as well as inside `probe`. `probe` handles the
    # faults it expects, but this method's contract is stronger: it must NEVER
    # raise, whatever the prober does, because Compose runs
    # `db:seed && foreman start` and an exception escaping here would stop the web
    # server from booting over a service that is merely unreachable.
    def await(target, prober:, sleeper:)
      detail = nil
      ATTEMPTS.times do |attempt|
        begin
          ok, detail = prober.call(target.fetch(:url))
        rescue StandardError => error
          ok = false
          detail = error.class.name
        end
        return Check.new(service: target.fetch(:service), url: target.fetch(:url), ok: true, detail: detail) if ok

        begin
          sleeper.call(SLEEP_SECONDS) unless attempt == ATTEMPTS - 1
        rescue StandardError
          nil
        end
      end
      Check.new(service: target.fetch(:service), url: target.fetch(:url), ok: false, detail: detail)
    end
    private_class_method :await

    # Returns [ok, detail]. `detail` names the fault in the same vocabulary
    # GatewayClient uses, so a preflight line and a failed turn read alike.
    def probe(url)
      uri = URI(url)
      response = Net::HTTP.start(uri.host, uri.port, open_timeout: TIMEOUT_SECONDS,
        read_timeout: TIMEOUT_SECONDS) { |http| http.request(Net::HTTP::Get.new(uri)) }
      code = response.code.to_i
      # The gateway and validator /healthz handlers answer a ready service with
      # 204 No Content, never 200 — their own Docker healthchecks assert exactly
      # StatusNoContent. Matching that here is load-bearing: treating only 200 as
      # healthy reported both services "unexpected HTTP 204" — i.e. UNREACHABLE —
      # on every `docker compose up`, even when they were fully healthy.
      return [ true, "healthy" ] if code == 204
      return [ false, "not ready (503) — no usable provider credential in that container" ] if code == 503

      [ false, "unexpected HTTP #{code}" ]
    rescue SocketError
      [ false, "name did not resolve — the containers do not share a network" ]
    rescue Errno::ECONNREFUSED
      [ false, "connection refused — the container is not listening (crash-looping or exited)" ]
    rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error
      [ false, "timed out after #{TIMEOUT_SECONDS}s" ]
    rescue StandardError => error
      [ false, error.class.name ]
    end
    private_class_method :probe
  end
end
