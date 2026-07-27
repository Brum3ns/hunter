require "net/http"

module Assistant
  # Runs one Ansible-draft validation against the validator and returns its
  # single terminal event. Structurally identical to GatewayClient (see there
  # for the full transport-failure rationale) but the validator answers with
  # one event object, not an array, and carries its own service-specific
  # readiness/saturation vocabulary (Task 4): `validator_not_ready` /
  # `validator_saturated`, never the gateway's `gateway_*` strings.
  module ValidatorClient
    class Error < StandardError
      attr_reader :code

      def initialize(code)
        @code = code.to_s
        super(@code)
      end
    end

    # A transport-level failure that never reached the validator's own error
    # vocabulary (connect refused, no reply, response too large, not JSON).
    class TransportFailure < StandardError
      attr_reader :reason

      def initialize(reason)
        @reason = reason
        super(reason.to_s)
      end
    end
    private_constant :TransportFailure

    TRANSPORT_ERROR_CODES = {
      "timeout" => "validator_timeout",
      "unreachable" => "validator_unreachable",
      "too_large" => "validator_response_too_large",
      "malformed" => "validator_malformed_response"
    }.freeze

    module_function

    def validate(envelope)
      body = fetch(envelope)
      if body.key?("error")
        raw_code = body.dig("error", "code")
        raise Error, TRANSPORT_ERROR_CODES[raw_code] || raw_code.presence || "validator_error"
      end
      raise Error, "invalid_response" unless body["schema_version"] == 1 && body["event"].is_a?(Hash)

      body["event"]
    end

    def endpoint
      "#{ENV.fetch('ASSISTANT_VALIDATOR_URL', 'http://assistant-validator:8082')}/validations"
    end

    def token
      ENV.fetch("ASSISTANT_VALIDATOR_INGRESS_TOKEN")
    end

    # The validator's own ReadTimeout/WriteTimeout is 310s (Task 4), mirroring
    # the gateway. Wait a little past that for the same reason GatewayClient
    # does: never give up on a connection the validator is still legitimately
    # servicing, while staying bounded rather than open-ended.
    def read_timeout_seconds
      Assistant::Config::HARD_LIMITS.fetch(:grant_ttl_seconds) + 30
    end

    def open_timeout_seconds
      5
    end

    # Never raises: every failure becomes {"error" => {"code" => ...}} so
    # `validate` has a single place that turns a body into an event or an Error.
    def fetch(envelope)
      JSON.parse(post(endpoint, JSON.generate(envelope), token))
    rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error
      { "error" => { "code" => "validator_timeout" } }
    rescue TransportFailure => failure
      { "error" => { "code" => TRANSPORT_ERROR_CODES.fetch(failure.reason, "validator_unreachable") } }
    rescue JSON::ParserError
      { "error" => { "code" => "validator_malformed_response" } }
    rescue SystemCallError, IOError, SocketError, EOFError, OpenSSL::SSL::SSLError
      { "error" => { "code" => "validator_unreachable" } }
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

    # Streams the response body and aborts as soon as it exceeds the shared
    # cap, rather than buffering an unbounded body and checking its size after
    # the fact — the response is untrusted the same way the gateway's is.
    def capped_body(response)
      buffer = +""
      response.read_body do |chunk|
        buffer << chunk
        raise TransportFailure, "too_large" if buffer.bytesize > Assistant::GatewayClient::MAX_RESPONSE_BYTES
      end
      buffer
    end
    private_class_method :capped_body
  end
end
