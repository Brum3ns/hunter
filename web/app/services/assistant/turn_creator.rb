module Assistant
  module TurnCreator
    class Rejected < StandardError
      attr_reader :code

      def initialize(code)
        @code = code
        super(code)
      end
    end

    class InvalidContext < Rejected
      attr_reader :index

      def initialize(index, code)
        @index = index
        super(code)
      end
    end

    module_function

    def call(conversation:, user:, body:, context_refs:)
      turn = nil
      raw_grant = nil

      Assistant::Conversation.transaction do
        setting = Assistant::Setting.lock.first || Assistant::Setting.instance.lock!
        profile = Assistant::ProviderProfile.lock.find(conversation.provider_profile_id)
        conversation.lock!
        backend = Assistant::ChatBackend.slug_for(profile)
        verify_dispatch!(conversation, user, setting, profile, backend)
        Assistant::RateLimiter.consume!(user: user, action: "turn_start", now: Time.current)
        turn = conversation.append_user_turn!(body: body, context_refs: [])
        raw_grant = Assistant::Grants::Issuer.call(
          turn: turn,
          resources: [],
          tools: Assistant::Grants::Issuer::CHAT_TOOLS
        )
        Assistant::Audit.record!(
          event: "turn.created",
          attributes: audit_attributes(turn, status: "created", operation: "turn_create")
        )
      end

      dispatch(turn, raw_grant)
    ensure
      raw_grant&.clear
    end

    def verify_dispatch!(conversation, user, setting, profile, backend)
      raise Rejected, "conversation_not_found" unless user && conversation.user_id == user.id
      raise Rejected, "legacy_provider_retired" unless backend
      raise Rejected, "assistant_disabled" unless
        Assistant::Config.enabled? && setting.assistant_enabled?
      raise Rejected, "conversation_unavailable" unless
        conversation.status == "active" && conversation.expires_at.future?
      raise Rejected, "provider_profile_unavailable" unless profile.enabled? && profile.reviewed_at.present?
    end
    private_class_method :verify_dispatch!

    def resolve_contexts!(context_refs, user)
      references = Array(context_refs)
      raise Rejected, "too_many_references" if references.length > Assistant::Config.max_records

      seen = Set.new
      references.each_with_index.map do |reference, index|
        attributes = exact_reference(reference, index)
        key = [ attributes.fetch("type"), attributes.fetch("id") ]
        raise InvalidContext.new(index, "duplicate_reference") unless seen.add?(key)

        record = Assistant::Context::Resolver.find(
          type: attributes.fetch("type"), id: attributes.fetch("id"), user: user
        )
        raise InvalidContext.new(index, "not_found") unless record

        disclosure = Assistant::Context::Catalog.serialize!(
          type: attributes.fetch("type"), record: record
        )
        {
          resource: { type: disclosure.fetch(:type), id: disclosure.fetch(:id).to_s },
          reference: {
            type: disclosure.fetch(:type),
            id: disclosure.fetch(:id).to_s,
            label: disclosure_label(disclosure),
            serializer_version: "v#{disclosure.fetch(:schema_version)}"
          }
        }
      rescue KeyError
        raise InvalidContext.new(index, "unsupported_type")
      rescue Assistant::Context::Catalog::UnsafeContentError
        raise InvalidContext.new(index, "unsafe_content")
      rescue Assistant::Context::Catalog::TooLargeError
        raise InvalidContext.new(index, "too_large")
      end
    end
    private_class_method :resolve_contexts!

    def exact_reference(reference, index)
      attributes = reference.respond_to?(:to_unsafe_h) ? reference.to_unsafe_h : reference.to_h
      attributes = attributes.stringify_keys
      raise InvalidContext.new(index, "invalid_reference") unless attributes.keys.sort == %w[id type]

      type = attributes.fetch("type").to_s
      id = attributes.fetch("id").to_s
      raise InvalidContext.new(index, "unsupported_type") unless
        Assistant::ContextReference::RESOURCE_TYPES.include?(type)
      raise InvalidContext.new(index, "invalid_reference") if id.blank? || id.length > 255

      { "type" => type, "id" => id }
    rescue NoMethodError, TypeError
      raise InvalidContext.new(index, "invalid_reference")
    end
    private_class_method :exact_reference

    def disclosure_label(disclosure)
      data = disclosure.fetch(:data)
      candidates = [
        data[:name], data[:host], data[:title], data[:sid], data[:id], disclosure.fetch(:id)
      ]
      candidates.find(&:present?).to_s.first(255)
    end
    private_class_method :disclosure_label

    def dispatch(turn, raw_grant)
      if turn.provider_profile.claude_code?
        prompt = turn.user_message&.body
        Assistant::Turn.transaction do
          turn.lock!
          raise ArgumentError, "turn requires one user message" if prompt.blank?
          turn.update!(status: "queued", queued_at: Time.current)
        end
        Assistant::TurnJob.perform_later(
          turn_id: turn.id, claude: true, prompt: prompt, turn_grant: raw_grant
        )
        return turn.reload
      end

      envelope = Assistant::Turn.transaction do
        setting = Assistant::Setting.lock.find(Assistant::Setting.instance.id)
        profile = Assistant::ProviderProfile.lock.find(turn.provider_profile_id)
        turn.lock!
        raise Rejected, "assistant_disabled" unless
          Assistant::Config.enabled? && setting.assistant_enabled?
        raise Rejected, "provider_profile_unavailable" unless
          profile.enabled? && profile.reviewed_at.present?

        Assistant::TurnDispatcher.call(turn: turn, raw_grant: raw_grant)
      end
      # Enqueued here, after the transaction above has actually committed —
      # not inside it, and not inside TurnDispatcher.call's own `with_lock`
      # (which only re-joins this same transaction). Solid Queue's `queue`
      # database is separate from the primary one in production, so the job
      # can be picked up the instant it is enqueued; enqueuing any earlier
      # risks a worker reading the turn before the "queued" write is visible,
      # hitting the job's own status guard, and silently stranding the turn.
      # A failure here is caught below exactly like any other dispatch
      # failure, so the turn is never left stuck in "queued".
      Assistant::TurnJob.perform_later(turn_id: turn.id, envelope: envelope)
      turn.reload
    rescue Rejected => error
      interrupt_dispatch!(turn, reason: error.code)
    rescue StandardError
      interrupt_dispatch!(turn, reason: "assistant_dispatch_unavailable")
    end
    private_class_method :dispatch

    def interrupt_dispatch!(turn, reason:)
      Assistant::Turn.transaction do
        turn.lock!
        unless turn.terminal?
          turn.update!(
            status: "interrupted",
            error_code: reason,
            completed_at: Time.current
          )
          Assistant::TurnGrant.where(turn: turn, revoked_at: nil).update_all(
            revoked_at: Time.current, updated_at: Time.current
          )
          Assistant::Audit.record!(
            event: "turn.dispatch_failed",
            attributes: audit_attributes(
              turn,
              status: "retryable",
              operation: "turn_dispatch",
              reason: reason
            )
          )
        end
      end
      turn.reload
    end
    private_class_method :interrupt_dispatch!

    def audit_attributes(turn, status:, operation:, reason: nil)
      metadata = { operation: operation, outcome: status }
      metadata[:reason] = reason if reason
      {
        correlation_id: turn.correlation_id,
        user_id: turn.user_id,
        conversation_id: turn.conversation_id,
        turn_id: turn.id,
        provider_profile_id: turn.provider_profile_id,
        status: status,
        model: turn.provider_profile.model,
        metadata: metadata
      }
    end
    private_class_method :audit_attributes
  end
end
