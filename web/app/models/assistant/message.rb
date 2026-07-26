module Assistant
  class Message < ApplicationRecord
    ROLES = %w[user assistant system_event].freeze

    self.table_name = "assistant_messages"

    belongs_to :conversation, class_name: "Assistant::Conversation", inverse_of: :messages
    belongs_to :turn, class_name: "Assistant::Turn", optional: true, inverse_of: :messages

    encrypts :body

    validates :role, inclusion: { in: ROLES }
    validates :body, presence: true, length: { maximum: 65_536 }
    validates :sequence,
      numericality: { only_integer: true, greater_than_or_equal_to: 0 },
      uniqueness: { scope: :conversation_id }
    validate :turn_belongs_to_conversation
    validate :content_is_immutable, on: :update

    private

    def turn_belongs_to_conversation
      return if turn.nil? || turn.conversation_id == conversation_id

      errors.add(:turn, "must belong to the conversation")
    end

    def content_is_immutable
      %i[conversation_id turn_id role body sequence].each do |attribute|
        errors.add(attribute.to_s.delete_suffix("_id").to_sym, "cannot be changed") if
          will_save_change_to_attribute?(attribute)
      end
    end
  end
end
