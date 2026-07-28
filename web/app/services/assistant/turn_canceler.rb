module Assistant
  module TurnCanceler
    module_function

    def call(turn:, user:)
      raise ActiveRecord::RecordNotFound unless user && turn.user_id == user.id

      Assistant::Turn.transaction do
        turn.lock!
        return turn if turn.terminal?

        turn.update!(status: "canceled", error_code: nil, completed_at: Time.current)
        Assistant::TurnGrant.where(turn: turn, revoked_at: nil).update_all(
          revoked_at: Time.current, updated_at: Time.current
        )
        Assistant::Audit.record!(
          event: "turn.canceled",
          attributes: {
            correlation_id: turn.correlation_id,
            user_id: turn.user_id,
            conversation_id: turn.conversation_id,
            turn_id: turn.id,
            provider_profile_id: turn.provider_profile_id,
            status: "canceled",
            model: turn.provider_profile.model,
            metadata: { operation: "turn_cancel", outcome: "canceled" }
          }
        )
      end
      turn.reload
    end
  end
end
