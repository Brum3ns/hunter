require "digest"

module Assistant
  class ValidationRequest < ApplicationRecord
    STATUSES = %w[pending valid invalid failed expired].freeze
    TERMINAL_STATUSES = %w[valid invalid failed expired].freeze

    self.table_name = "assistant_validation_requests"

    belongs_to :turn, class_name: "Assistant::Turn"
    belongs_to :turn_grant, class_name: "Assistant::TurnGrant"
    belongs_to :draft, class_name: "Assistant::Draft", optional: true

    serialize :result, coder: JSON
    encrypts :source
    encrypts :result

    before_validation :set_source_digest, on: :create

    validates :status, inclusion: { in: STATUSES }
    validates :source_digest, format: { with: /\A\h{64}\z/ }
    validates :expires_at, presence: true
    validates :source, presence: true, if: -> { status == "pending" }
    validates :result, presence: true, if: :terminal?
    validate :bindings_match
    validate :bindings_are_immutable, on: :update

    def terminal?
      TERMINAL_STATUSES.include?(status)
    end

    private

    def set_source_digest
      self.source_digest = Digest::SHA256.hexdigest(source.to_s) if source.present?
    end

    def bindings_match
      return unless turn && turn_grant

      errors.add(:turn_grant, "must belong to the turn") if turn_grant.turn_id != turn_id
      errors.add(:expires_at, "cannot exceed the turn grant") if
        expires_at && turn_grant.expires_at && expires_at > turn_grant.expires_at
      return unless draft && draft.turn_id != turn_id

      errors.add(:draft, "must belong to the turn")
    end

    def bindings_are_immutable
      %i[turn_id turn_grant_id draft_id source_digest expires_at].each do |attribute|
        next unless will_save_change_to_attribute?(attribute)

        errors.add(attribute.to_s.delete_suffix("_id").to_sym, "cannot be changed")
      end
    end
  end
end
