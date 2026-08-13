module Assistant
  module Config
    HARD_LIMITS = {
      grant_ttl_seconds: 300,
      max_records: 10,
      max_tool_calls: 8,
      max_result_bytes: 524_288,
      max_total_bytes: 2_097_152,
      turn_starts_per_minute: 10,
      turn_starts_per_hour: 60,
      max_concurrent_turns: 2,
      max_validations_per_turn: 1,
      max_creates_per_minute: 5,
      max_creates_per_hour: 30
    }.freeze

    module_function

    def enabled?
      Activation.state.active
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

    def max_creates_per_minute
      bounded_ceiling("ASSISTANT_MAX_CREATES_PER_MINUTE", HARD_LIMITS[:max_creates_per_minute])
    end

    def max_creates_per_hour
      bounded_ceiling("ASSISTANT_MAX_CREATES_PER_HOUR", HARD_LIMITS[:max_creates_per_hour])
    end

    REQUIRED_SETTINGS = {
      "ADMIN_USERNAME" => "missing_admin_username",
      "CONTROL_CENTER_COMMAND_ALLOWLIST" => "missing_command_allowlist",
      "ASSISTANT_ANSIBLE_MODULE_ALLOWLIST" => "missing_ansible_module_allowlist"
    }.freeze

    # Configuration problems disable the assistant with a stable reason. They never
    # abort boot: an operator must still be able to reach the app and read why.
    def configuration_reasons
      reasons = REQUIRED_SETTINGS.filter_map do |key, reason|
        reason if configured(key).to_s.strip.blank?
      end

      begin
        transcript_retention_days
        audit_retention_days
      rescue ArgumentError
        reasons << "invalid_retention_window"
      end

      reasons
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
