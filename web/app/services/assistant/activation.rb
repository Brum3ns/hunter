module Assistant
  # Activation is derived: a valid provider key file means that provider is on.
  # ASSISTANT_ENABLED is a kill override only, never an opt-in.
  module Activation
    State = Data.define(:active, :available_slugs, :reason)

    module_function

    def state(directory: ProviderCredentials::DEFAULT_DIRECTORY)
      return State.new(active: false, available_slugs: [], reason: "disabled_by_environment") if killed?

      reasons = Config.configuration_reasons
      return State.new(active: false, available_slugs: [], reason: reasons.first) if reasons.any?

      slugs = ProviderCredentials.available_slugs(directory: directory)
      if slugs.empty?
        State.new(active: false, available_slugs: [], reason: "no_provider_credentials")
      else
        State.new(active: true, available_slugs: slugs, reason: "active")
      end
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
