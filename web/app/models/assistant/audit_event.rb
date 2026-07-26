module Assistant
  class AuditEvent < ApplicationRecord
    self.table_name = "assistant_audit_events"

    belongs_to :user, optional: true
    belongs_to :conversation, class_name: "Assistant::Conversation", optional: true
    belongs_to :turn, class_name: "Assistant::Turn", optional: true
    belongs_to :provider_profile, class_name: "Assistant::ProviderProfile", optional: true

    validates :event, presence: true, length: { maximum: 100 },
      format: { with: /\A[a-z0-9_.-]+\z/ }
    validates :status, :model, :tool, :resource_type, :resource_id,
      :target_type, :target_id, length: { maximum: 255 }, allow_nil: true
    validates :byte_count, :input_tokens, :output_tokens, :latency_ms,
      numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
    validates :content_hash, format: { with: /\A\h{64}\z/ }, allow_nil: true
    validates :expires_at, presence: true
  end
end
