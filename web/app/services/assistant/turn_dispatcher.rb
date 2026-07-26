module Assistant
  module TurnDispatcher
    module_function

    def call(turn:, raw_grant:)
      turn.with_lock do
        raise ArgumentError, "turn must be created" unless turn.status == "created"

        grant = grant_for!(turn, raw_grant)
        message = turn.user_message
        raise ArgumentError, "turn requires one user message" unless message

        body = {
          "schema_version" => 1,
          "correlation_id" => turn.correlation_id,
          "turn_id" => turn.id,
          "conversation_id" => turn.conversation_id,
          "user_id" => turn.user_id,
          "provider_profile" => turn.provider_profile.dispatch_snapshot.deep_stringify_keys,
          "user_message" => message.body,
          "context_references" => turn.context_references.order(:id).map do |reference|
            {
              "type" => reference.resource_type,
              "id" => reference.resource_id,
              "label" => reference.label,
              "serializer_version" => reference.serializer_version
            }
          end,
          "turn_grant" => raw_grant,
          "expires_at" => grant.expires_at.iso8601
        }
        Assistant::QueueContracts.validate_turn_job!(body)

        turn.update!(status: "queued", queued_at: Time.current)
        Assistant::Broker.publish(
          exchange: "assistant.turns",
          routing_key: "assistant.gateway.turns",
          body: body,
          persistent: false,
          expiration: Assistant::Config::HARD_LIMITS.fetch(:grant_ttl_seconds) * 1_000
        )
        body
      end
    end

    def grant_for!(turn, raw)
      grant = Assistant::TurnGrant.find_by(token_digest: Assistant::TurnGrant.digest(raw))
      raise ArgumentError, "grant does not match turn" unless grant&.turn_id == turn.id
      raise ArgumentError, "grant is unavailable" unless grant.expires_at.future? && grant.revoked_at.nil?

      grant
    end
    private_class_method :grant_for!
  end
end
