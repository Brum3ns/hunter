require "digest"

module Assistant
  class ActionReceipt
    STATUSES = %w[
      created updated submitted queued cancelled exported restored idempotent_replay
    ].freeze

    class << self
      def replay(grant:, tool:, idempotency_key:)
        digest = Digest::SHA256.hexdigest(idempotency_key.to_s)
        event = Assistant::AuditEvent.where(
          event: "machine.action_receipt", turn_id: grant.turn_id, tool: tool.to_s
        ).where("metadata ->> 'idempotency_digest' = ?", digest).order(:id).last
        return unless event

        issue!(grant: grant, tool: tool, status: "idempotent_replay",
          target_type: event.target_type, target_id: event.target_id,
          idempotency_key: idempotency_key, replayed: true)
      end

      def issue!(grant:, tool:, status:, target_type:, target_id:, idempotency_key:, replayed:)
        capability = Assistant::CapabilityCatalog.load.tool!(tool)
        validate!(
          capability: capability,
          status: status,
          target_type: target_type,
          target_id: target_id,
          idempotency_key: idempotency_key
        )

        receipt_id = SecureRandom.uuid
        digest = Digest::SHA256.hexdigest(idempotency_key.to_s)
        receipt = deep_freeze({
          "receipt_id" => receipt_id,
          "tool" => capability.fetch("name"),
          "status" => replayed ? "idempotent_replay" : status.to_s,
          "target" => { "type" => target_type.to_s, "id" => target_id.to_s },
          "human_user_id" => grant.user_id,
          "turn_id" => grant.turn_id,
          "idempotency_digest" => digest,
          "replayed" => !!replayed,
          "occurred_at" => Time.current.iso8601
        })

        Assistant::Audit.record!(event: "machine.action_receipt", attributes: {
          correlation_id: grant.turn.correlation_id,
          user_id: grant.user_id,
          conversation_id: grant.conversation_id,
          turn_id: grant.turn_id,
          provider_profile_id: grant.provider_profile_id,
          status: receipt.fetch("status"),
          tool: receipt.fetch("tool"),
          target_type: target_type.to_s,
          target_id: target_id.to_s,
          metadata: {
            receipt_id: receipt_id,
            effect: capability.fetch("effect"),
            idempotency_digest: digest,
            replayed: !!replayed
          }
        })

        receipt
      end

      private

      def deep_freeze(value)
        case value
        when Hash
          value.each { |key, nested| deep_freeze(key); deep_freeze(nested) }
        when Array
          value.each { |nested| deep_freeze(nested) }
        end
        value.freeze
      end

      def validate!(capability:, status:, target_type:, target_id:, idempotency_key:)
        if Assistant::TurnGrant::READ_EFFECTS.include?(capability.fetch("effect"))
          raise ArgumentError, "action receipts require an effectful capability"
        end
        raise ArgumentError, "unsupported receipt status" unless STATUSES.include?(status.to_s)
        raise ArgumentError, "target type is invalid" unless target_type.to_s.match?(/\A[a-z][a-z0-9_]{0,63}\z/)
        raise ArgumentError, "target id is invalid" if target_id.to_s.blank? || target_id.to_s.length > 255
        raise ArgumentError, "idempotency key is required" if idempotency_key.to_s.blank?
        raise ArgumentError, "idempotency key is too long" if idempotency_key.to_s.bytesize > 255
      end
    end
  end
end
