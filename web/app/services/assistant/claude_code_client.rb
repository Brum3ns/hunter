require "net/http"

module Assistant
  # Runs one chat turn against the assistant-claude service (the official Claude
  # Code CLI on the operator's subscription) and returns an ordered event array
  # in the SAME shape Assistant::GatewayClient produced, so Assistant::TurnJob's
  # ingestion path and the chat UI work unchanged.
  #
  # Like GatewayClient, this never lets a transport exception escape: every
  # failure becomes an `error` event with a stable `claude_*` code, so a failed
  # turn is recorded, never stranded. There is no activation/on-off state — an
  # unconfigured backend simply yields `claude_not_configured` on the turn.
  module ClaudeCodeClient
    module_function

    # `poster` is injectable for tests: a lambda taking the request body hash and
    # returning the parsed response hash. Defaults to the real HTTP POST.
    def run_turn(turn:, prompt:, turn_grant: nil, poster: method(:post))
      url = ENV["ASSISTANT_CLAUDE_URL"].to_s
      return [ error_event(turn, "claude_not_configured") ] if url.strip.empty?

      request_body = { "prompt" => prompt, "session_id" => turn.conversation.claude_session_id }
      request_body["turn_grant"] = turn_grant if turn_grant.present?
      body = poster.call(request_body)

      if body.is_a?(Hash) && body.key?("error")
        return [ error_event(turn, body.dig("error", "code").presence || "claude_error") ]
      end
      session_id = body["session_id"] if body.is_a?(Hash)
      reply = body["reply"] if body.is_a?(Hash)
      return [ error_event(turn, "claude_malformed_response") ] if session_id.blank? || reply.blank?

      turn.conversation.update!(claude_session_id: session_id)
      [ assistant_message_event(turn, reply), completed_event(turn) ]
    end

    # Real HTTP POST to the assistant-claude service. Never raises: every
    # transport fault maps to a { "error" => { "code" => ... } } body so run_turn
    # has one place to turn a response into events.
    def post(request_body)
      uri = URI("#{ENV.fetch('ASSISTANT_CLAUDE_URL')}/chat")
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["Authorization"] = "Bearer #{ENV.fetch('ASSISTANT_CLAUDE_INGRESS_TOKEN')}"
      request.body = JSON.generate(request_body)
      response = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: read_timeout_seconds) do |http|
        http.request(request)
      end
      JSON.parse(response.body.to_s)
    rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error
      { "error" => { "code" => "claude_timeout" } }
    rescue JSON::ParserError
      { "error" => { "code" => "claude_malformed_response" } }
    rescue SocketError
      { "error" => { "code" => "claude_dns_failure" } }
    rescue Errno::ECONNREFUSED
      { "error" => { "code" => "claude_connection_refused" } }
    rescue SystemCallError, IOError, OpenSSL::SSL::SSLError
      { "error" => { "code" => "claude_unreachable" } }
    rescue KeyError
      { "error" => { "code" => "claude_not_configured" } }
    end
    private_class_method :post

    # A little past the service's own turn ceiling so Rails never abandons a turn
    # the CLI is still legitimately producing.
    def read_timeout_seconds
      330
    end
    private_class_method :read_timeout_seconds

    def assistant_message_event(turn, body)
      event(turn, "assistant_message", { "body" => body })
    end
    private_class_method :assistant_message_event

    # The CLI does not report token counts in Phase 1; EventIngestor fetches these
    # keys, so provide zeros.
    def completed_event(turn)
      event(turn, "completed", { "input_tokens" => 0, "output_tokens" => 0, "tool_call_count" => 0 })
    end
    private_class_method :completed_event

    def error_event(turn, code)
      event(turn, "error", { "code" => code.to_s.first(100) })
    end

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
