module Assistant
  module Config
    HARD_LIMITS = {
      grant_ttl_seconds: 300,
      max_records: 10,
      max_tool_calls: 8,
      max_result_bytes: 65_536,
      max_total_bytes: 262_144,
      turn_starts_per_minute: 10,
      turn_starts_per_hour: 60,
      max_concurrent_turns: 2,
      max_validations_per_turn: 1
    }.freeze

    module_function

    def enabled?(directory: ProviderCredentials::DEFAULT_DIRECTORY)
      Activation.state(directory: directory).active
    end

    def transcript_retention_days
      bounded_integer("ASSISTANT_TRANSCRIPT_DAYS", default: 7, range: 1..30)
    end

    def audit_retention_days
      bounded_integer("ASSISTANT_AUDIT_DAYS", default: 90, range: 1..365)
    end

    def grant_ttl
      bounded_ceiling("ASSISTANT_GRANT_TTL_SECONDS", HARD_LIMITS[:grant_ttl_seconds]).seconds
    end

    def max_records
      bounded_ceiling("ASSISTANT_MAX_RECORDS", HARD_LIMITS[:max_records])
    end

    def max_tool_calls
      bounded_ceiling("ASSISTANT_MAX_TOOL_CALLS", HARD_LIMITS[:max_tool_calls])
    end

    def max_result_bytes
      bounded_ceiling("ASSISTANT_MAX_RESULT_BYTES", HARD_LIMITS[:max_result_bytes])
    end

    def max_total_bytes
      bounded_ceiling("ASSISTANT_MAX_TOTAL_BYTES", HARD_LIMITS[:max_total_bytes])
    end

    def turn_starts_per_minute
      bounded_ceiling("ASSISTANT_TURN_STARTS_PER_MINUTE", HARD_LIMITS[:turn_starts_per_minute])
    end

    def turn_starts_per_hour
      bounded_ceiling("ASSISTANT_TURN_STARTS_PER_HOUR", HARD_LIMITS[:turn_starts_per_hour])
    end

    def max_concurrent_turns
      bounded_ceiling("ASSISTANT_MAX_CONCURRENT_TURNS", HARD_LIMITS[:max_concurrent_turns])
    end

    def max_validations_per_turn
      bounded_ceiling("ASSISTANT_MAX_VALIDATIONS_PER_TURN", HARD_LIMITS[:max_validations_per_turn])
    end

    def validate_production!
      return unless enabled?

      errors = []
      errors << "ADMIN_USERNAME must be set" if configured("ADMIN_USERNAME").to_s.strip.blank?
      errors << "CONTROL_CENTER_COMMAND_ALLOWLIST must be set" if configured("CONTROL_CENTER_COMMAND_ALLOWLIST").to_s.strip.blank?
      errors << "ASSISTANT_ANSIBLE_MODULE_ALLOWLIST must be set" if configured("ASSISTANT_ANSIBLE_MODULE_ALLOWLIST").to_s.strip.blank?

      %i[transcript_retention_days audit_retention_days].each do |reader|
        public_send(reader)
      rescue ArgumentError => error
        errors << error.message
      end

      raise "Invalid assistant production configuration: #{errors.join('; ')}" if errors.any?
    end

    def configured(key)
      ENV[key]
    end

    def bounded_ceiling(key, ceiling)
      [ [ Integer(configured(key) || ceiling), 1 ].max, ceiling ].min
    rescue ArgumentError, TypeError
      ceiling
    end
    private_class_method :bounded_ceiling

    def bounded_integer(key, default:, range:)
      value = Integer(configured(key) || default)
      raise ArgumentError, "#{key} must be in #{range}" unless range.cover?(value)

      value
    rescue TypeError
      raise ArgumentError, "#{key} must be in #{range}"
    end
    private_class_method :bounded_integer
  end
end
