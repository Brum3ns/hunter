module Assistant
  module KillSwitch
    Result = Data.define(:status, :revoked_grants, :disabled_identities, :interrupted_turns)

    module_function

    def disable!(user:)
      now = Time.current
      result = nil

      Assistant::Setting.transaction do
        setting = Assistant::Setting.lock.first || Assistant::Setting.instance.lock!
        setting.update!(assistant_enabled: false, disabled_at: now, disabled_by: user)

        turns = Assistant::Turn.where.not(status: Assistant::Turn::TERMINAL_STATUSES)
          .order(:id).lock.to_a
        grants = Assistant::TurnGrant.where(revoked_at: nil).order(:id).lock.to_a
        identities = Assistant::ServiceIdentity.where(enabled: true).order(:id).lock.to_a

        interrupted_turns = Assistant::Turn.where(id: turns.map(&:id)).update_all(
          status: "interrupted",
          error_code: "assistant_disabled",
          completed_at: now,
          updated_at: now
        )
        revoked_grants = Assistant::TurnGrant.where(id: grants.map(&:id)).update_all(
          revoked_at: now, updated_at: now
        )
        disabled_identities = Assistant::ServiceIdentity.where(id: identities.map(&:id)).update_all(
          enabled: false, updated_at: now
        )
        Assistant::Audit.record!(event: "kill_switch.disabled", attributes: {
          user_id: user&.id,
          status: "disabled",
          metadata: { operation: "kill_switch", outcome: "disabled" }
        })
        result = Result.new(
          status: "disabled",
          revoked_grants: revoked_grants,
          disabled_identities: disabled_identities,
          interrupted_turns: interrupted_turns
        )
      end

      result
    end
  end
end
