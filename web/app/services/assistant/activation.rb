module Assistant
  # Activation is provider-key independent. ASSISTANT_ENABLED remains a kill
  # override, while required configuration must still be complete.
  module Activation
    State = Data.define(:active, :available_slugs, :reason)

    module_function

    def state
      return State.new(active: false, available_slugs: [], reason: "disabled_by_environment") if killed?

      reasons = Config.configuration_reasons
      return State.new(active: false, available_slugs: [], reason: reasons.first) if reasons.any?

      State.new(active: true, available_slugs: ChatBackend::SLUGS, reason: "active")
    end

    # Metadata-only summary for callers to fold into their own audit event; it
    # is deliberately not shaped like Assistant::Audit::METADATA_KEYS and this
    # module never calls Assistant::Audit.record! itself.
    def audit_payload(state)
      { active: state.active, reason: state.reason, available_slugs: state.available_slugs }
    end

    def killed?
      raw = Config.configured("ASSISTANT_ENABLED")
      return false if raw.nil? || raw.to_s.strip.empty?

      ActiveModel::Type::Boolean.new.cast(raw) == false
    end
    private_class_method :killed?
  end
end
