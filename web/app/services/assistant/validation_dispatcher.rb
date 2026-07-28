require "digest"

module Assistant
  module ValidationDispatcher
    VALIDATION_VERSION = "ansible-syntax-v1"
    EVENT_KEYS = %w[schema_version event_id validation_id correlation_id status codes].freeze
    STATUSES = %w[valid invalid failed].freeze

    class InvalidDraft < StandardError
      attr_reader :result

      def initialize(result)
        @result = result
        super("Ansible static validation rejected the draft")
      end
    end

    class DispatchFailed < StandardError; end
    class InvalidEvent < StandardError; end

    module_function

    def call(turn:, grant:, service_identity:, yaml:)
      validate_bindings!(turn, grant)
      static = Assistant::DraftValidation::AnsibleStatic.call(yaml)
      raise InvalidDraft, static unless static.valid?

      request = nil
      envelope = nil
      Assistant::ValidationRequest.transaction do
        setting = Assistant::Setting.lock.first || Assistant::Setting.instance.lock!
        identity = Assistant::ServiceIdentity.lock.find(service_identity.id)
        Assistant::RateLimiter.consume!(
          user: turn.user, action: "validation:#{turn.id}", now: Time.current
        )
        locked_turn = Assistant::Turn.lock.find(turn.id)
        locked_grant = Assistant::TurnGrant.lock.find(grant.id)
        validate_authority!(setting, identity, locked_turn, locked_grant)
        request = Assistant::ValidationRequest.create!(
          turn: locked_turn,
          turn_grant: locked_grant,
          status: "pending",
          source: static.normalized,
          expires_at: [ locked_grant.expires_at, 5.minutes.from_now ].min
        )
        envelope = {
          "schema_version" => 1,
          "validation_id" => request.id,
          "correlation_id" => locked_turn.correlation_id,
          "turn_id" => locked_turn.id,
          "source" => request.source,
          "expires_at" => request.expires_at.iso8601
        }
      end
      # The validator call happens AFTER the transaction above commits, never
      # inside it: `Broker.publish` was a local, fire-and-forget AMQP write,
      # but a synchronous HTTP round trip in its place would hold four row
      # locks (Setting, ServiceIdentity, Turn, TurnGrant) open for as long as
      # the validator takes to answer. The validator now answers synchronously
      # with the terminal event, so `ingest!` is fed directly from the
      # response — there is no separate async completion event to wait for.
      event = Assistant::ValidatorClient.validate(envelope)
      ingest!(event)
      request.id
    rescue InvalidDraft, Assistant::RateLimiter::LimitExceeded
      raise
    rescue StandardError
      fail_request!(request) if request&.persisted?
      raise DispatchFailed, "Ansible validation dispatch failed"
    end

    def ingest!(payload)
      event = normalize_event(payload)
      request = Assistant::ValidationRequest.find_by(id: event.fetch("validation_id"))
      raise InvalidEvent, "validation_not_found" unless request

      request.with_lock do
        return :duplicate if request.terminal_event_id == event.fetch("event_id")
        raise InvalidEvent, "validation_already_terminal" if request.terminal?
        raise InvalidEvent, "validation_expired" unless request.expires_at.future?
        raise InvalidEvent, "correlation_mismatch" unless request.turn.correlation_id == event.fetch("correlation_id")

        normalized = event.fetch("status") == "failed" ? nil : request.source
        request.update!(
          status: event.fetch("status"),
          result: {
            "normalized" => normalized,
            "codes" => event.fetch("codes"),
            "messages" => event.fetch("codes").map { |code| message_for(code) },
            "validation_version" => VALIDATION_VERSION
          },
          source: nil,
          terminal_event_id: event.fetch("event_id"),
          completed_at: Time.current
        )
        Assistant::Audit.record!(event: "validation.completed", attributes: {
          correlation_id: request.turn.correlation_id,
          user_id: request.turn.user_id,
          conversation_id: request.turn.conversation_id,
          turn_id: request.turn_id,
          provider_profile_id: request.turn.provider_profile_id,
          status: request.status,
          validation_codes: event.fetch("codes"),
          content_hash: request.source_digest,
          metadata: { operation: "ansible_syntax", outcome: request.status }
        })
      end
      :accepted
    end

    def normalize_event(payload)
      event = payload.to_h.deep_stringify_keys
      raise InvalidEvent, "invalid_event" unless event.keys.sort == EVENT_KEYS.sort
      raise InvalidEvent, "invalid_event" unless event["schema_version"] == 1
      raise InvalidEvent, "invalid_event" unless valid_uuid?(event["event_id"]) && valid_uuid?(event["validation_id"]) && valid_uuid?(event["correlation_id"])
      raise InvalidEvent, "invalid_event" unless STATUSES.include?(event["status"])
      codes = event["codes"]
      raise InvalidEvent, "invalid_event" unless codes.is_a?(Array) && codes.length <= 50 &&
        codes.all? { |code| code.is_a?(String) && code.match?(/\A[a-z0-9_.-]{1,100}\z/) }

      event
    end
    private_class_method :normalize_event

    def validate_bindings!(turn, grant)
      valid = turn && grant && grant.turn_id == turn.id && grant.conversation_id == turn.conversation_id &&
        grant.user_id == turn.user_id && grant.provider_profile_id == turn.provider_profile_id &&
        grant.revoked_at.nil? && grant.expires_at.future? && grant.tools.include?("validate_ansible_draft")
      raise ArgumentError, "turn grant is not valid for Ansible validation" unless valid
    end
    private_class_method :validate_bindings!

    def validate_authority!(setting, identity, turn, grant)
      valid = Assistant::Config.enabled? && setting.assistant_enabled? &&
        identity.enabled? && identity.role == "mcp_reader" && !turn.terminal?
      raise ArgumentError, "assistant validation authority is unavailable" unless valid

      validate_bindings!(turn, grant)
    end
    private_class_method :validate_authority!

    def fail_request!(request)
      request.update!(
        status: "failed",
        result: {
          "normalized" => nil,
          "codes" => [ "validator_dispatch_failed" ],
          "messages" => [ "Ansible syntax validation could not be dispatched." ],
          "validation_version" => VALIDATION_VERSION
        },
        source: nil,
        completed_at: Time.current
      )
    rescue ActiveRecord::ActiveRecordError
      nil
    end
    private_class_method :fail_request!

    def valid_uuid?(value)
      value.to_s.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/)
    end
    private_class_method :valid_uuid?

    def message_for(code)
      code == "ansible_syntax_invalid" ? "Ansible syntax check rejected the draft." : "Ansible syntax validation failed."
    end
    private_class_method :message_for
  end
end
