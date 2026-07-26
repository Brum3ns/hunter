module Assistant
  class Turn < ApplicationRecord
    STATUSES = %w[created queued running completed failed canceled interrupted].freeze
    TERMINAL_STATUSES = %w[completed failed canceled interrupted].freeze

    self.table_name = "assistant_turns"

    belongs_to :conversation, class_name: "Assistant::Conversation", inverse_of: :turns
    belongs_to :user
    belongs_to :provider_profile, class_name: "Assistant::ProviderProfile"
    has_many :context_references, class_name: "Assistant::ContextReference",
      dependent: :delete_all, inverse_of: :turn
    has_many :messages, class_name: "Assistant::Message", dependent: :nullify,
      inverse_of: :turn
    has_many :drafts, class_name: "Assistant::Draft", dependent: :delete_all,
      inverse_of: :turn
    has_one :turn_grant, class_name: "Assistant::TurnGrant", dependent: :delete,
      inverse_of: :turn
    has_one :user_message, -> { where(role: "user") },
      class_name: "Assistant::Message", inverse_of: :turn

    before_validation :set_correlation_id, on: :create

    validates :correlation_id, presence: true, uniqueness: true
    validates :status, inclusion: { in: STATUSES }
    validates :input_tokens, :output_tokens, :tool_call_count,
      numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validate :bindings_match_conversation
    validate :identity_is_immutable, on: :update

    def terminal?
      TERMINAL_STATUSES.include?(status)
    end

    private

    def set_correlation_id
      self.correlation_id ||= SecureRandom.uuid
    end

    def bindings_match_conversation
      return unless conversation

      errors.add(:user, "must match the conversation") if user_id != conversation.user_id
      return if provider_profile_id == conversation.provider_profile_id

      errors.add(:provider_profile, "must match the conversation")
    end

    def identity_is_immutable
      %i[conversation_id user_id provider_profile_id correlation_id].each do |attribute|
        next unless will_save_change_to_attribute?(attribute)

        error_attribute = attribute == :correlation_id ? attribute : attribute.to_s.delete_suffix("_id").to_sym
        errors.add(error_attribute, "cannot be changed")
      end
    end
  end
end
