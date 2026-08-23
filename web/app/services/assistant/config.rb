module Assistant
  module Config
    HARD_LIMITS = {
      grant_ttl_seconds: 1_800,
      max_records: 10,
      max_tool_calls: 128,
      max_result_bytes: 1_048_576,
      max_total_bytes: 16_777_216,
      max_effects_per_turn: 64,
      max_effects_per_hour: 240,
      max_launches_per_turn: 32,
      max_launches_per_hour: 120,
      turn_starts_per_minute: 10,
      turn_starts_per_hour: 60,
      max_concurrent_turns: 2,
      max_validations_per_turn: 1,
      max_creates_per_minute: 5,
      max_creates_per_hour: 30
    }.freeze

    DEFAULT_LIMITS = {
      grant_ttl_seconds: 1_800,
      max_records: 10,
      max_tool_calls: 64,
      max_result_bytes: 1_048_576,
      max_total_bytes: 16_777_216,
      max_effects_per_turn: 32,
      max_effects_per_hour: 120,
      max_launches_per_turn: 16,
      max_launches_per_hour: 60
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
      bounded_limit("ASSISTANT_GRANT_TTL_SECONDS", :grant_ttl_seconds).seconds
    end

    def max_records
      bounded_limit("ASSISTANT_MAX_RECORDS", :max_records)
    end

    def max_tool_calls
      bounded_limit("ASSISTANT_MAX_TOOL_CALLS", :max_tool_calls)
    end

    def max_result_bytes
      bounded_limit("ASSISTANT_MAX_RESULT_BYTES", :max_result_bytes)
    end

    def max_total_bytes
      bounded_limit("ASSISTANT_MAX_TOTAL_BYTES", :max_total_bytes)
    end

    def max_effects_per_turn
      bounded_limit("ASSISTANT_MAX_EFFECTS_PER_TURN", :max_effects_per_turn)
    end

    def max_effects_per_hour
      bounded_limit("ASSISTANT_MAX_EFFECTS_PER_HOUR", :max_effects_per_hour)
    end

    def max_launches_per_turn
      bounded_limit("ASSISTANT_MAX_LAUNCHES_PER_TURN", :max_launches_per_turn)
    end

    def max_launches_per_hour
      bounded_limit("ASSISTANT_MAX_LAUNCHES_PER_HOUR", :max_launches_per_hour)
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

    def bounded_limit(key, name)
      configured_value = configured(key)
      return DEFAULT_LIMITS.fetch(name) if configured_value.nil?

      bounded_ceiling(key, HARD_LIMITS.fetch(name))
    end
    private_class_method :bounded_limit

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
