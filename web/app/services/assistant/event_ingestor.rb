module Assistant
  module EventIngestor
    class InvalidEvent < StandardError
      attr_reader :code

      def initialize(code)
        @code = code
        super(code)
      end
    end

    module_function

    def call(payload)
      event = Assistant::QueueContracts.validate_assistant_event!(payload)
      turn = Assistant::Turn.find_by(id: event["turn_id"])
      raise InvalidEvent, "turn_not_found" unless turn

      turn.with_lock do
        validate_bindings!(turn, event)
        return :duplicate if ingested?(event["event_id"])
        raise InvalidEvent, "terminal_replay" if turn.terminal?

        ingest!(turn, event["kind"], event["data"])
        record_audit!(turn, event)
      end
      :accepted
    rescue Assistant::QueueContracts::InvalidPayload => error
      raise InvalidEvent, error.code
    end

    def validate_bindings!(turn, event)
      valid = turn.correlation_id == event["correlation_id"] &&
        turn.provider_profile_id == event["provider_profile_id"]
      raise InvalidEvent, "binding_mismatch" unless valid
    end
    private_class_method :validate_bindings!

    def ingested?(event_id)
      Assistant::AuditEvent.where(event: "queue.event_ingested")
        .where("metadata ->> 'request_id' = ?", event_id).exists?
    end
    private_class_method :ingested?

    def ingest!(turn, kind, data)
      case kind
      when "assistant_message"
        turn.conversation.messages.create!(
          turn: turn,
          role: "assistant",
          body: data.fetch("body"),
          sequence: turn.conversation.messages.maximum(:sequence).to_i + 1
        )
        mark_running!(turn)
      when "draft"
        turn.conversation.drafts.create!(turn: turn, **data.symbolize_keys)
        mark_running!(turn)
      when "completed"
        turn.update!(
          status: "completed",
          completed_at: Time.current,
          input_tokens: data.fetch("input_tokens"),
          output_tokens: data.fetch("output_tokens"),
          tool_call_count: data.fetch("tool_call_count")
        )
        revoke_grants!(turn)
      when "error"
        turn.update!(status: "failed", completed_at: Time.current, error_code: data.fetch("code"))
        revoke_grants!(turn)
      end
    end
    private_class_method :ingest!

    def mark_running!(turn)
      return if turn.status == "running"

      turn.update!(status: "running", started_at: turn.started_at || Time.current)
    end
    private_class_method :mark_running!

    def revoke_grants!(turn)
      Assistant::TurnGrant.where(turn: turn, revoked_at: nil).update_all(
        revoked_at: Time.current,
        updated_at: Time.current
      )
    end
    private_class_method :revoke_grants!

    def record_audit!(turn, event)
      Assistant::Audit.record!(
        event: "queue.event_ingested",
        attributes: {
          correlation_id: turn.correlation_id,
          user_id: turn.user_id,
          conversation_id: turn.conversation_id,
          turn_id: turn.id,
          provider_profile_id: turn.provider_profile_id,
          status: "accepted",
          metadata: {
            operation: event["kind"],
            outcome: "accepted",
            request_id: event["event_id"]
          }
        }
      )
    end
    private_class_method :record_audit!
  end
end
