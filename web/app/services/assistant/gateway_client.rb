require "net/http"

module Assistant
  # Runs one turn against the gateway and returns its ordered event array. The
  # gateway holds no Hunter identity beyond the ingress bearer token, so this
  # is a plain, single-attempt HTTP POST: Rails calls out, the gateway answers
  # on the same connection with either an event array or an error envelope.
  #
  # Every failure mode below — a non-2xx error envelope, a dropped connection,
  # a stalled read, an oversize body, or a malformed body — surfaces as
  # `GatewayClient::Error` with a stable `#code`. Nothing here ever lets a
  # transport exception escape to the caller; `Assistant::TurnJob` depends on
  # that to turn a failure into a recorded "error" event instead of crashing.
  module GatewayClient
    class Error < StandardError
      attr_reader :code

      def initialize(code)
        @code = code.to_s
        super(@code)
      end
    end

    # A transport-level failure that never reached the gateway's own error
    # vocabulary (connect refused, no reply, response too large, not JSON).
    # Kept distinct from `Error` so `fetch` can map it to a gateway_-prefixed
    # code without confusing it with a genuine gateway response.
    class TransportFailure < StandardError
      attr_reader :reason

      def initialize(reason)
        @reason = reason
        super(reason.to_s)
      end
    end
    private_constant :TransportFailure

    # The gateway relays untrusted provider output; this bounds the read
    # BEFORE the body is ever handed to JSON.parse. Rehomed from the AMQP
    # consumer's MAX_EVENT_BYTES (event_consumer.rb), which Task 6 removes.
    MAX_RESPONSE_BYTES = 300_000

    TRANSPORT_ERROR_CODES = {
      "timeout" => "gateway_timeout",
      "unreachable" => "gateway_unreachable",
      "too_large" => "gateway_response_too_large",
      "malformed" => "gateway_malformed_response"
    }.freeze

    module_function

    def run_turn(envelope)
      body = fetch(envelope)
      if body.key?("error")
        raw_code = body.dig("error", "code")
        raise Error, TRANSPORT_ERROR_CODES[raw_code] || raw_code.presence || "gateway_error"
      end
      raise Error, "invalid_response" unless body["schema_version"] == 1 && body["events"].is_a?(Array)

      body["events"]
    end

    def endpoint
      "#{ENV.fetch('ASSISTANT_GATEWAY_URL', 'http://assistant-gateway:8081')}/turns"
    end

    def token
      ENV.fetch("ASSISTANT_GATEWAY_INGRESS_TOKEN")
    end

    # The gateway's own ReadTimeout/WriteTimeout is 310s (Task 3). Wait a
    # little past that so Rails never gives up on a connection the gateway is
    # still legitimately servicing (a slow, in-flight provider call), while
    # staying bounded rather than open-ended.
    def read_timeout_seconds
      Assistant::Config::HARD_LIMITS.fetch(:grant_ttl_seconds) + 30
    end

    def open_timeout_seconds
      5
    end

    # Never raises: every failure becomes {"error" => {"code" => ...}} so
    # `run_turn` has a single place that turns a body into events or an Error.
    def fetch(envelope)
      JSON.parse(post(endpoint, JSON.generate(envelope), token))
    rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error
      { "error" => { "code" => "gateway_timeout" } }
    rescue TransportFailure => failure
      { "error" => { "code" => TRANSPORT_ERROR_CODES.fetch(failure.reason, "gateway_unreachable") } }
    rescue JSON::ParserError
      { "error" => { "code" => "gateway_malformed_response" } }
    rescue SystemCallError, IOError, SocketError, EOFError, OpenSSL::SSL::SSLError
      { "error" => { "code" => "gateway_unreachable" } }
    end
    private_class_method :fetch

    def post(url, json, bearer)
      uri = URI(url)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["Authorization"] = "Bearer #{bearer}"
      request.body = json
      Net::HTTP.start(uri.host, uri.port,
        open_timeout: open_timeout_seconds, read_timeout: read_timeout_seconds, write_timeout: 10) do |http|
        http.request(request) { |response| return capped_body(response) }
      end
    end
    private_class_method :post

    # Streams the response body and aborts as soon as it exceeds the cap,
    # rather than buffering an unbounded body and checking its size after the
    # fact — the whole point of the cap is to bound memory on untrusted
    # provider output before it ever reaches JSON.parse.
    def capped_body(response)
      buffer = +""
      response.read_body do |chunk|
        buffer << chunk
        raise TransportFailure, "too_large" if buffer.bytesize > MAX_RESPONSE_BYTES
      end
      buffer
    end
    private_class_method :capped_body
  end
end
