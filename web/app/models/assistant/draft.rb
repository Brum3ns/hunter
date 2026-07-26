require "digest"

module Assistant
  class Draft < ApplicationRecord
    ARTIFACT_TYPES = %w[whiterabbit_template ansible_playbook].freeze
    VALIDATION_STATUSES = %w[pending valid invalid failed].freeze

    self.table_name = "assistant_drafts"

    belongs_to :conversation, class_name: "Assistant::Conversation", inverse_of: :drafts
    belongs_to :turn, class_name: "Assistant::Turn", inverse_of: :drafts

    serialize :validation_details, coder: JSON
    encrypts :content
    encrypts :validation_details

    before_validation :set_content_digest

    validates :artifact_type, inclusion: { in: ARTIFACT_TYPES }
    validates :name, presence: true, length: { maximum: 200 }
    validates :content, presence: true, length: { maximum: 262_144 }
    validates :validation_status, inclusion: { in: VALIDATION_STATUSES }
    validates :validation_version, presence: true
    validates :content_digest, format: { with: /\A\h{64}\z/ }
    validate :validation_details_are_present
    validate :turn_belongs_to_conversation
    validate :draft_content_is_immutable, on: :update

    private

    def set_content_digest
      self.content_digest = Digest::SHA256.hexdigest(content.to_s) if content.present?
    end

    def turn_belongs_to_conversation
      return if turn.nil? || turn.conversation_id == conversation_id

      errors.add(:turn, "must belong to the conversation")
    end

    def validation_details_are_present
      errors.add(:validation_details, "can't be nil") if validation_details.nil?
    end

    def draft_content_is_immutable
      %i[conversation_id turn_id artifact_type content].each do |attribute|
        errors.add(attribute.to_s.delete_suffix("_id").to_sym, "cannot be changed") if
          will_save_change_to_attribute?(attribute)
      end
    end
  end
end
