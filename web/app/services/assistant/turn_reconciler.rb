module Assistant
  module TurnReconciler
    module_function

    def call(turn:, now: Time.current)
      Assistant::Turn.transaction do
        turn.lock!
        return turn if turn.terminal?

        grants = Assistant::TurnGrant.lock.where(turn: turn).to_a
        return turn if grants.empty? || grants.any? { |grant| grant.expires_at > now }

        turn.update!(
          status: "interrupted",
          error_code: "assistant_turn_expired",
          completed_at: now
        )
        Assistant::TurnGrant.where(id: grants.map(&:id), revoked_at: nil).update_all(
          revoked_at: now, updated_at: now
        )
        Assistant::Audit.record!(
          event: "turn.expired",
          attributes: {
            correlation_id: turn.correlation_id,
            user_id: turn.user_id,
            conversation_id: turn.conversation_id,
            turn_id: turn.id,
            provider_profile_id: turn.provider_profile_id,
            status: "interrupted",
            model: turn.provider_profile.model,
            metadata: {
              operation: "turn_reconcile",
              outcome: "interrupted",
              reason: "assistant_turn_expired"
            }
          }
        )
      end
      turn.reload
    end
  end
end
