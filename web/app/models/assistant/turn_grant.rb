require "digest"

module Assistant
  class TurnGrant < ApplicationRecord
    IMMUTABLE_ATTRIBUTES = %i[
      user_id
      conversation_id
      turn_id
      provider_profile_id
      token_digest
      resources
      tools
      read_scopes
      write_scopes
      expires_at
      max_calls
      max_result_bytes
      max_total_bytes
    ].freeze

    # The closed set of module slugs a grant may authorize for read-only
    # browsing. No wildcard is ever accepted. Grows as read modules ship.
    READ_SCOPES = %w[
      targets
      cves
      vulnerabilities
      sitemap
      programs
      control_center_templates
      control_center_jobs
      control_center_ansible
    ].freeze

    # The closed set of independently revocable Control Center authoring
    # scopes. No wildcard is ever accepted.
    WRITE_SCOPES = %w[
      control_center_templates_write
      control_center_templates_edit
      control_center_ansible_write
      control_center_ansible_edit
    ].freeze

    self.table_name = "assistant_turn_grants"

    belongs_to :user
    belongs_to :conversation, class_name: "Assistant::Conversation"
    belongs_to :turn, class_name: "Assistant::Turn", inverse_of: :turn_grant
    belongs_to :provider_profile, class_name: "Assistant::ProviderProfile"

    validates :token_digest, presence: true, uniqueness: true,
      format: { with: /\A\h{64}\z/ }
    validates :expires_at, presence: true
    validates :max_calls,
      numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 8 }
    validates :call_count,
      numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :max_result_bytes, :max_total_bytes,
      numericality: { only_integer: true, greater_than: 0 }
    validates :returned_bytes, :reserved_bytes,
      numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validate :bindings_match_turn
    validate :usage_is_within_limits
    validate :read_scopes_are_known
    validate :write_scopes_are_known
    validate :scope_is_immutable, on: :update

    def self.digest(raw)
      Digest::SHA256.hexdigest(raw.to_s)
    end

    private

    def bindings_match_turn
      return unless turn && conversation

      errors.add(:conversation, "must match the turn") if turn.conversation_id != conversation_id
      errors.add(:user, "must match the turn") if turn.user_id != user_id
      return if turn.provider_profile_id == provider_profile_id

      errors.add(:provider_profile, "must match the turn")
    end

    def usage_is_within_limits
      if call_count.to_i > max_calls.to_i
        errors.add(:call_count, "cannot exceed max calls")
      end
      if max_total_bytes.to_i < max_result_bytes.to_i
        errors.add(:max_total_bytes, "must cover one result")
      end
      return if returned_bytes.to_i + reserved_bytes.to_i <= max_total_bytes.to_i

      errors.add(:returned_bytes, "and reserved bytes exceed the total budget")
    end

    def read_scopes_are_known
      extra = Array(read_scopes) - READ_SCOPES
      errors.add(:read_scopes, "contains unknown slugs: #{extra.join(', ')}") if extra.any?
    end

    def write_scopes_are_known
      extra = Array(write_scopes) - WRITE_SCOPES
      errors.add(:write_scopes, "contains unknown slugs: #{extra.join(', ')}") if extra.any?
    end

    def scope_is_immutable
      IMMUTABLE_ATTRIBUTES.each do |attribute|
        next unless will_save_change_to_attribute?(attribute)

        error_attribute = attribute.to_s.delete_suffix("_id").to_sym
        errors.add(error_attribute, "cannot be changed")
      end
    end
  end
end
