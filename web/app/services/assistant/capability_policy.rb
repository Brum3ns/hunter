module Assistant
  class CapabilityPolicy
    READ_EFFECTS = %w[read analyze validate].freeze

    Result = Data.define(:allowed, :reason, :tool) do
      def allowed?
        allowed
      end
    end

    class << self
      def check(tool:, settings: Assistant::Setting.instance)
        capability = Assistant::CapabilityCatalog.load.tool!(tool)
        return denied(capability) unless capability.fetch("rollout") == "enabled"
        return denied(capability) unless settings.operational_access_enabled?
        return denied(capability) if settings.disabled_capability_tools.include?(capability.fetch("name"))
        return denied(capability) if settings.disabled_capability_effects.include?(capability.fetch("effect"))
        return denied(capability) if settings.disabled_capability_modules.include?(capability.fetch("module"))
        return denied(capability) if legacy_control_center_write_disabled?(capability, settings)

        Result.new(allowed: true, reason: nil, tool: capability)
      end

      private

      def denied(capability)
        Result.new(allowed: false, reason: "capability_disabled", tool: capability)
      end

      def legacy_control_center_write_disabled?(capability, settings)
        capability.fetch("module").start_with?("control_center_") &&
          !READ_EFFECTS.include?(capability.fetch("effect")) &&
          !settings.control_center_write_enabled?
      end
    end
  end
end
