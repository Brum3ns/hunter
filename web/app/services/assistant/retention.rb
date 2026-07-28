module Assistant
  module Retention
    BATCH_SIZE = 500

    module_function

    def purge!(now: Time.current)
      now = now.in_time_zone
      counts = {
        conversations: delete_in_batches(Assistant::Conversation.where(expires_at: ..now)),
        grants: revoke_grants_in_batches(now),
        validations: delete_in_batches(Assistant::ValidationRequest.where(expires_at: ..now)),
        audits: delete_in_batches(Assistant::AuditEvent.where(expires_at: ..now))
      }
      Rails.logger.info(
        "assistant_retention conversations=#{counts[:conversations]} " \
        "grants=#{counts[:grants]} validations=#{counts[:validations]} audits=#{counts[:audits]}"
      )
      counts
    end

    def delete_in_batches(scope)
      count = 0
      loop do
        ids = scope.reorder(:id).limit(BATCH_SIZE).pluck(:id)
        break if ids.empty?

        scope.klass.transaction do
          rows = scope.klass.where(id: ids).lock
          rows.load
          count += scope.klass.where(id: ids).delete_all
        end
      end
      count
    end
    private_class_method :delete_in_batches

    def revoke_grants_in_batches(now)
      count = 0
      scope = Assistant::TurnGrant.where(revoked_at: nil, expires_at: ..now)
      loop do
        ids = scope.reorder(:id).limit(BATCH_SIZE).pluck(:id)
        break if ids.empty?

        Assistant::TurnGrant.transaction do
          rows = Assistant::TurnGrant.where(id: ids).lock
          rows.load
          count += Assistant::TurnGrant.where(id: ids, revoked_at: nil).update_all(
            revoked_at: now, updated_at: now
          )
        end
      end
      count
    end
    private_class_method :revoke_grants_in_batches
  end
end
