module Assistant
  class ProviderProfile < ApplicationRecord
    RETENTION_POSTURES = %w[standard zero_data_retention].freeze

    self.table_name = "assistant_provider_profiles"

    belongs_to :created_by, class_name: "User", inverse_of: :assistant_provider_profiles
    has_many :conversations, class_name: "Assistant::Conversation",
      dependent: :restrict_with_error, inverse_of: :provider_profile
    has_many :turns, class_name: "Assistant::Turn", dependent: :restrict_with_error,
      inverse_of: :provider_profile

    normalizes :name, with: ->(name) { name.strip }

    before_validation :apply_catalog_entry

    validates :name, presence: true, uniqueness: { case_sensitive: false }
    validates :catalog_slug, presence: true, uniqueness: true
    validates :provider, :model, :secret_ref, presence: true
    validates :input_limit, :output_limit,
      numericality: { only_integer: true, greater_than: 0 }
    validates :tool_call_limit,
      numericality: {
        only_integer: true,
        greater_than_or_equal_to: 1,
        less_than_or_equal_to: Assistant::Config::HARD_LIMITS.fetch(:max_tool_calls)
      }
    validates :retention_posture, inclusion: { in: RETENTION_POSTURES }
    validate :reviewed_when_enabled

    # The synthetic Claude Code profile carries no API secret; dispatch routes it
    # to Assistant::ClaudeCodeClient instead of the provider gateway.
    def claude_code?
      catalog_slug == "claude_code"
    end

    def dispatch_snapshot
      {
        profile_id: id,
        catalog_slug: catalog_slug,
        provider: provider,
        model: model,
        secret_ref: secret_ref,
        input_limit: input_limit,
        output_limit: output_limit,
        tool_call_limit: tool_call_limit,
        retention_posture: retention_posture,
        reviewed_at: reviewed_at&.iso8601
      }.freeze
    end

    private

    def apply_catalog_entry
      entry = Assistant::ProviderCatalog.fetch!(catalog_slug)
      self.provider = entry.provider
      self.model = entry.model
      self.secret_ref = entry.secret_ref
      self.input_limit = entry.input_limit
      self.output_limit = entry.output_limit
      self.retention_posture ||= entry.retention_posture
    rescue KeyError
      errors.add(:catalog_slug, "is not approved")
    end

    def reviewed_when_enabled
      return unless enabled? && reviewed_at.blank?

      errors.add(:reviewed_at, "must be present when enabled")
    end
  end
end
