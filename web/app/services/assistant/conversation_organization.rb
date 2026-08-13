module Assistant
  module ConversationOrganization
    MAX_CONVERSATIONS = 1_000

    class InvalidOrder < StandardError
      attr_reader :code

      def initialize(code)
        @code = code
        super(code)
      end
    end

    module_function

    def reorder!(user:, conversation_ids:)
      ids = validate_ids!(conversation_ids)
      reordered = nil

      Assistant::Conversation.transaction do
        user.lock!
        conversations = user.assistant_conversations.lock.order(:id).to_a
        expected_ids = conversations.map(&:id)
        unless ids.length == expected_ids.length && ids.sort == expected_ids.sort
          raise InvalidOrder, "conversation_order_stale"
        end

        by_id = conversations.index_by(&:id)
        ids.each_with_index do |id, position|
          by_id.fetch(id).update_columns(history_position: position)
        end
        Assistant::Audit.record!(
          event: "conversation.reordered",
          attributes: {
            user_id: user.id,
            status: "accepted",
            metadata: {
              operation: "conversation_reorder",
              outcome: "accepted",
              count: ids.length
            }
          }
        )
        reordered = ids.map { |id| by_id.fetch(id) }
      end

      reordered
    end

    def validate_ids!(conversation_ids)
      unless conversation_ids.instance_of?(Array) &&
          conversation_ids.length <= MAX_CONVERSATIONS &&
          conversation_ids.all? { |id| id.instance_of?(Integer) && id.positive? } &&
          conversation_ids.uniq.length == conversation_ids.length
        raise InvalidOrder, "invalid_order"
      end

      conversation_ids
    end
    private_class_method :validate_ids!
  end
end
