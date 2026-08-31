require "net/http"

module Assistant
  # Runs one chat turn against the dedicated Codex CLI service and translates
  # its response into the same ordered event contract consumed by TurnJob.
  # Transport and service failures are collapsed to a closed set of stable
  # codes; provider output and exception messages never enter an error event.
  module CodexClient
    class ResponseTooLarge < StandardError; end
    private_constant :ResponseTooLarge

    MAX_RESPONSE_BYTES = 300_000
    MAX_CONTINUITY_ID_LENGTH = 255
    MAX_REPLY_LENGTH = 65_536

    ERROR_CODES = %w[
      codex_not_configured
      codex_login_required
      codex_timeout
      codex_unreachable
      codex_dns_failure
      codex_connection_refused
      codex_malformed_response
      codex_usage_limit
      codex_error
    ].freeze

    module_function

    def run_turn(turn:, prompt:, poster: method(:post))
      return [ error_event(turn, "codex_not_configured") ] if
        ENV["ASSISTANT_CODEX_URL"].to_s.strip.empty?

      request_body = {
        "prompt" => prompt,
        "thread_id" => turn.conversation.codex_thread_id
      }
      body = poster.call(request_body)

      if body.is_a?(Hash) && body.key?("error")
        return [ error_event(turn, service_error_code(body["error"])) ]
      end

      thread_id = body["thread_id"] if body.is_a?(Hash)
      reply = body["reply"] if body.is_a?(Hash)
      return [ error_event(turn, "codex_malformed_response") ] if
        !bounded_string?(thread_id, MAX_CONTINUITY_ID_LENGTH) ||
          !bounded_string?(reply, MAX_REPLY_LENGTH)

      turn.conversation.update!(codex_thread_id: thread_id)
      [ assistant_message_event(turn, reply), completed_event(turn) ]
    end

    def endpoint
      base_url = ENV.fetch("ASSISTANT_CODEX_URL", "http://assistant-codex:8084")
      "#{base_url.delete_suffix('/')}/chat"
    end

    def post(request_body)
      uri = URI(endpoint)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["Authorization"] =
        "Bearer #{ENV.fetch('ASSISTANT_CODEX_INGRESS_TOKEN')}"
      request.body = JSON.generate(request_body)
      response_body = nil
      Net::HTTP.start(
        uri.host,
        uri.port,
        open_timeout: 5,
        read_timeout: read_timeout_seconds
      ) do |http|
        http.request(request) { |response| response_body = capped_body(response) }
      end
      JSON.parse(response_body)
    rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error
      { "error" => { "code" => "codex_timeout" } }
    rescue JSON::ParserError, ResponseTooLarge
      { "error" => { "code" => "codex_malformed_response" } }
    rescue SocketError
      { "error" => { "code" => "codex_dns_failure" } }
    rescue Errno::ECONNREFUSED
      { "error" => { "code" => "codex_connection_refused" } }
    rescue SystemCallError, IOError, OpenSSL::SSL::SSLError
      { "error" => { "code" => "codex_unreachable" } }
    rescue KeyError
      { "error" => { "code" => "codex_not_configured" } }
    end
    private_class_method :post

    def capped_body(response)
      buffer = +""
      response.read_body do |chunk|
        buffer << chunk
        raise ResponseTooLarge if buffer.bytesize > MAX_RESPONSE_BYTES
      end
      buffer
    end
    private_class_method :capped_body

    def bounded_string?(value, max_length)
      value.is_a?(String) && value.present? && value.length <= max_length
    end
    private_class_method :bounded_string?

    def read_timeout_seconds
      330
    end
    private_class_method :read_timeout_seconds

    def service_error_code(error)
      raw_code = error["code"] if error.is_a?(Hash)
      ERROR_CODES.include?(raw_code) ? raw_code : "codex_error"
    end
    private_class_method :service_error_code

    def assistant_message_event(turn, body)
      event(turn, "assistant_message", { "body" => body })
    end
    private_class_method :assistant_message_event

    def completed_event(turn)
      event(
        turn,
        "completed",
        { "input_tokens" => 0, "output_tokens" => 0, "tool_call_count" => 0 }
      )
    end
    private_class_method :completed_event

    def error_event(turn, code)
      safe_code = ERROR_CODES.include?(code) ? code : "codex_error"
      event(turn, "error", { "code" => safe_code })
    end
    private_class_method :error_event

    def event(turn, kind, data)
      {
        "schema_version" => 1,
        "event_id" => SecureRandom.uuid,
        "correlation_id" => turn.correlation_id,
        "turn_id" => turn.id,
        "provider_profile_id" => turn.provider_profile_id,
        "kind" => kind,
        "data" => data
      }
    end
    private_class_method :event
  end
end
