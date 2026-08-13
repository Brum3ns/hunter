module Assistant
  module Audit
    ATTRIBUTE_KEYS = %i[
      correlation_id
      user_id
      conversation_id
      turn_id
      provider_profile_id
      status
      model
      tool
      resource_type
      resource_id
      byte_count
      input_tokens
      output_tokens
      latency_ms
      validation_codes
      content_hash
      target_type
      target_id
      metadata
    ].freeze
    METADATA_KEYS = %w[operation reason limit outcome request_id source count].freeze

    module_function

    def record!(event:, attributes: {})
      attributes = attributes.to_h.symbolize_keys
      unknown = attributes.keys - ATTRIBUTE_KEYS
      raise ArgumentError, "unsupported audit attributes: #{unknown.join(', ')}" if unknown.any?

      attributes[:metadata] = normalize_metadata(attributes.fetch(:metadata, {}))
      Assistant::AuditEvent.create!(
        **attributes,
        event: event,
        expires_at: Assistant::Setting.instance.audit_retention_days.days.from_now
      )
    end

    def normalize_metadata(metadata)
      normalized = metadata.to_h.stringify_keys
      unknown = normalized.keys - METADATA_KEYS
      raise ArgumentError, "unsupported audit metadata: #{unknown.join(', ')}" if unknown.any?

      normalized.each_value do |value|
        unless value.nil? || value == true || value == false || value.is_a?(Numeric) || value.is_a?(String)
          raise ArgumentError, "audit metadata values must be scalar"
        end
        raise ArgumentError, "audit metadata values are too long" if value.is_a?(String) && value.length > 255
      end
      raise ArgumentError, "audit metadata is too large" if JSON.generate(normalized).bytesize > 1_024

      normalized
    end
    private_class_method :normalize_metadata
  end
end
