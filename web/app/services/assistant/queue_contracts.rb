module Assistant
  module QueueContracts
    class InvalidPayload < StandardError
      attr_reader :code

      def initialize(code)
        @code = code
        super(code)
      end
    end

    EVENT_KEYS = %w[schema_version event_id correlation_id turn_id provider_profile_id kind data].freeze
    EVENT_DATA_KEYS = {
      "progress" => %w[status],
      "assistant_message" => %w[body],
      "draft" => %w[artifact_type name content validation_details validation_status validation_version],
      "completed" => %w[input_tokens output_tokens tool_call_count],
      "error" => %w[code]
    }.freeze
    TURN_JOB_KEYS = %w[
      schema_version correlation_id turn_id conversation_id user_id provider_profile
      user_message context_references turn_grant expires_at
    ].freeze

    module_function

    def validate_turn_job!(payload)
      payload = payload.to_h.stringify_keys
      exact_keys!(payload, TURN_JOB_KEYS)
      version!(payload)
      uuid!(payload["correlation_id"])
      bounded_string!(payload["user_message"], 1..65_536)
      bounded_string!(payload["turn_grant"], 32..256)
      raise InvalidPayload, "too_many_contexts" if Array(payload["context_references"]).length > 10
      payload
    end

    def validate_assistant_event!(payload)
      payload = payload.to_h.deep_stringify_keys
      exact_keys!(payload, EVENT_KEYS)
      version!(payload)
      uuid!(payload["event_id"])
      uuid!(payload["correlation_id"])
      kind = payload["kind"].to_s
      expected_data_keys = EVENT_DATA_KEYS[kind]
      raise InvalidPayload, "unknown_event_kind" unless expected_data_keys

      data = payload["data"]
      raise InvalidPayload, "invalid_event_data" unless data.is_a?(Hash)
      exact_keys!(data, expected_data_keys)
      validate_event_data!(kind, data)
      payload
    end

    def exact_keys!(payload, expected)
      raise InvalidPayload, "invalid_keys" unless payload.keys.sort == expected.sort
    end
    private_class_method :exact_keys!

    def version!(payload)
      raise InvalidPayload, "unsupported_schema_version" unless payload["schema_version"] == 1
    end
    private_class_method :version!

    def uuid!(value)
      parsed = value.to_s.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i)
      raise InvalidPayload, "invalid_uuid" unless parsed
    end
    private_class_method :uuid!

    def bounded_string!(value, range)
      raise InvalidPayload, "invalid_string" unless value.is_a?(String) && range.cover?(value.length)
    end
    private_class_method :bounded_string!

    def validate_event_data!(kind, data)
      case kind
      when "progress"
        raise InvalidPayload, "invalid_status" unless %w[queued running].include?(data["status"])
      when "assistant_message"
        bounded_string!(data["body"], 1..65_536)
      when "draft"
        raise InvalidPayload, "invalid_artifact_type" unless
          %w[whiterabbit_template ansible_playbook].include?(data["artifact_type"])
        bounded_string!(data["name"], 1..200)
        bounded_string!(data["content"], 1..262_144)
        raise InvalidPayload, "invalid_validation_details" unless data["validation_details"].is_a?(Hash)
      when "completed"
        %w[input_tokens output_tokens tool_call_count].each do |key|
          raise InvalidPayload, "invalid_counter" unless data[key].is_a?(Integer) && data[key] >= 0
        end
        raise InvalidPayload, "invalid_counter" if data["tool_call_count"] > 8
      when "error"
        bounded_string!(data["code"], 1..100)
      end
    end
    private_class_method :validate_event_data!
  end
end
