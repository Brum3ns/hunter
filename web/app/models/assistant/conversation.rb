module Assistant
  class Conversation < ApplicationRecord
    STATUSES = %w[active closed].freeze
    CONTEXT_KEYS = %w[type resource_type id resource_id label serializer_version].freeze

    self.table_name = "assistant_conversations"

    belongs_to :user
    belongs_to :provider_profile, class_name: "Assistant::ProviderProfile"
    has_many :messages, class_name: "Assistant::Message", dependent: :delete_all,
      inverse_of: :conversation
    has_many :drafts, class_name: "Assistant::Draft", dependent: :delete_all,
      inverse_of: :conversation
    has_many :turns, class_name: "Assistant::Turn", dependent: :delete_all,
      inverse_of: :conversation

    before_validation :set_expiration, on: :create

    scope :history_ordered, -> {
      order(arel_table[:history_position].asc.nulls_last, updated_at: :desc, id: :desc)
    }

    validates :status, inclusion: { in: STATUSES }
    validates :title, presence: true, length: { maximum: 200 }
    validates :expires_at, presence: true
    validate :provider_profile_is_enabled, on: :create
    validate :bindings_are_immutable, on: :update

    class << self
      def start!(user:, provider_profile:)
        transaction do
          user.lock!
          minimum = where(user_id: user.id).minimum(:history_position)
          create!(
            user: user,
            provider_profile: provider_profile,
            history_position: minimum.nil? ? 0 : minimum - 1
          )
        end
      end
    end

    def rename_by!(actor:, title:)
      raise ActiveRecord::RecordNotFound unless actor && actor.id == user_id

      renamed = self.class.transaction do
        conversation = self.class.lock.find(id)
        conversation.update!(title: title.is_a?(String) ? title.strip : title)
        Assistant::Audit.record!(
          event: "conversation.renamed",
          attributes: {
            user_id: actor.id,
            conversation_id: conversation.id,
            status: "accepted",
            metadata: { operation: "conversation_rename", outcome: "accepted" }
          }
        )
        conversation
      end
      reload
      renamed
    end

    def append_user_turn!(body:, context_refs:)
      references = normalize_context_refs(context_refs)

      with_lock do
        ensure_accepting_turns!
        turn = turns.create!(user: user, provider_profile: provider_profile)
        references.each { |attributes| turn.context_references.create!(attributes) }
        messages.create!(
          turn: turn,
          role: "user",
          body: body,
          sequence: messages.maximum(:sequence).to_i + 1
        )
        turn
      end
    end

    def destroy_with_content!
      self.class.transaction do
        lock!
        destroy!
      end
    end

    private

    def set_expiration
      self.expires_at ||= Assistant::Setting.instance.transcript_retention_days.days.from_now
    end

    def provider_profile_is_enabled
      return if provider_profile&.enabled?

      errors.add(:provider_profile, "must be enabled")
    end

    def bindings_are_immutable
      errors.add(:user, "cannot be changed") if will_save_change_to_user_id?
      return unless will_save_change_to_provider_profile_id?

      errors.add(:provider_profile, "cannot be changed")
    end

    def normalize_context_refs(context_refs)
      references = Array(context_refs)
      raise ArgumentError, "too many context references" if references.length > Assistant::Config.max_records

      references.map do |reference|
        attributes = reference.to_h.stringify_keys
        unknown_keys = attributes.keys - CONTEXT_KEYS
        raise ArgumentError, "unknown context keys: #{unknown_keys.join(', ')}" if unknown_keys.any?

        {
          resource_type: attributes["resource_type"] || attributes.fetch("type"),
          resource_id: attributes["resource_id"] || attributes.fetch("id"),
          label: attributes.fetch("label"),
          serializer_version: attributes.fetch("serializer_version", "v1")
        }
      end
    end

    def ensure_accepting_turns!
      return if status == "active" && expires_at.future?

      raise ActiveRecord::RecordInvalid, self
    end
  end
end
