module Assistant
  class Setting < ApplicationRecord
    self.table_name = "assistant_settings"

    belongs_to :disabled_by, class_name: "User", optional: true

    validates :singleton_key, inclusion: { in: [ true ] }, uniqueness: true
    before_validation :normalize_capability_disables
    validate :transcript_retention_is_bounded
    validate :audit_retention_is_bounded
    validate :capability_disables_are_known

    class << self
      def instance
        first_or_create!(singleton_key: true, assistant_enabled: true)
      rescue ActiveRecord::RecordNotUnique
        find_by!(singleton_key: true)
      end

      def enable!
        instance.enable!
      end

      def disable!(user:)
        instance.disable!(user: user)
      end

      def enable_control_center_write!(user: nil)
        instance.enable_control_center_write!(user: user)
      end

      def disable_control_center_write!(user:)
        instance.disable_control_center_write!(user: user)
      end

      def enable_operational_access!(user:)
        instance.enable_operational_access!(user: user)
      end

      def disable_operational_access!(user:)
        instance.disable_operational_access!(user: user)
      end

      def enable_conversation_management!(user:)
        instance.enable_conversation_management!(user: user)
      end

      def disable_conversation_management!(user:)
        instance.disable_conversation_management!(user: user)
      end
    end

    def enable!
      update!(assistant_enabled: true, disabled_at: nil, disabled_by: nil)
    end

    def disable!(user:)
      update!(assistant_enabled: false, disabled_at: Time.current, disabled_by: user)
    end

    def enable_control_center_write!(user: nil)
      update!(control_center_write_enabled: true)
      Assistant::Audit.record!(
        event: "control_center_write.enabled",
    attributes: { user_id: user&.id, metadata: { operation: "control_center_write", outcome: "enabled" } }
      )
    end

    def disable_control_center_write!(user:)
      update!(control_center_write_enabled: false)
      Assistant::Audit.record!(
        event: "control_center_write.disabled",
        attributes: { user_id: user&.id, metadata: { operation: "control_center_write", outcome: "disabled" } }
      )
    end

    def enable_operational_access!(user:)
      update!(operational_access_enabled: true)
      audit_capability_setting(user: user, operation: "operational_access", outcome: "enabled")
    end

    def disable_operational_access!(user:)
      update!(operational_access_enabled: false)
      audit_capability_setting(user: user, operation: "operational_access", outcome: "disabled")
    end

    def update_capability_disables!(tools:, effects:, modules:, user:)
      update!(
        disabled_capability_tools: tools,
        disabled_capability_effects: effects,
        disabled_capability_modules: modules
      )
      Assistant::Audit.record!(event: "capability_policy.updated", attributes: {
        user_id: user&.id,
        metadata: {
          operation: "capability_policy", outcome: "updated",
          count: disabled_capability_tools.length + disabled_capability_effects.length +
            disabled_capability_modules.length
        }
      })
    end

    def enable_conversation_management!(user:)
      update!(conversation_management_enabled: true)
      Assistant::Audit.record!(
        event: "conversation_management.enabled",
        attributes: {
          user_id: user&.id,
          metadata: { operation: "conversation_management", outcome: "enabled" }
        }
      )
    end

    def disable_conversation_management!(user:)
      update!(conversation_management_enabled: false)
      Assistant::Audit.record!(
        event: "conversation_management.disabled",
        attributes: {
          user_id: user&.id,
          metadata: { operation: "conversation_management", outcome: "disabled" }
        }
      )
    end

    private

    def audit_capability_setting(user:, operation:, outcome:)
      Assistant::Audit.record!(event: "#{operation}.#{outcome}", attributes: {
        user_id: user&.id, metadata: { operation: operation, outcome: outcome }
      })
    end

    def normalize_capability_disables
      self.disabled_capability_tools = Array(disabled_capability_tools).map(&:to_s).reject(&:blank?).uniq
      self.disabled_capability_effects = Array(disabled_capability_effects).map(&:to_s).reject(&:blank?).uniq
      self.disabled_capability_modules = Array(disabled_capability_modules).map(&:to_s).reject(&:blank?).uniq
    end

    def capability_disables_are_known
      catalog = Assistant::CapabilityCatalog.load
      validate_capability_names(
        :disabled_capability_tools,
        catalog.tools.map { |tool| tool.fetch("name") }
      )
      validate_capability_names(
        :disabled_capability_effects,
        catalog.tools.map { |tool| tool.fetch("effect") }.uniq
      )
      validate_capability_names(
        :disabled_capability_modules,
        catalog.tools.map { |tool| tool.fetch("module") }.uniq
      )
    end

    def validate_capability_names(attribute, allowed)
      unknown = public_send(attribute) - allowed
      errors.add(attribute, "contains unknown names: #{unknown.join(', ')}") if unknown.any?
    end

    def transcript_retention_is_bounded
      return if (1..30).cover?(transcript_retention_days)

      errors.add(:transcript_retention_days, "must be in 1..30")
    end

    def audit_retention_is_bounded
      return if (1..365).cover?(audit_retention_days)

      errors.add(:audit_retention_days, "must be in 1..365")
    end
  end
end
