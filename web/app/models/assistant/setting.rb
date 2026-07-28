module Assistant
  class Setting < ApplicationRecord
    self.table_name = "assistant_settings"

    belongs_to :disabled_by, class_name: "User", optional: true

    validates :singleton_key, inclusion: { in: [ true ] }, uniqueness: true
    validate :transcript_retention_is_bounded
    validate :audit_retention_is_bounded

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
    end

    def enable!
      update!(assistant_enabled: true, disabled_at: nil, disabled_by: nil)
    end

    def disable!(user:)
      update!(assistant_enabled: false, disabled_at: Time.current, disabled_by: user)
    end

    private

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
