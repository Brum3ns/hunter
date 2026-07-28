module Assistant
  module MachineAuthenticator
    class Error < StandardError
      attr_reader :code

      def initialize(code)
        @code = code
        super(code)
      end
    end

    module_function

    def authenticate_service!(raw)
      identity = Assistant::ServiceIdentity.authenticate(raw, role: "mcp_reader")
      raise Error, "invalid_service_token" unless identity

      identity
    end

    def authenticate_grant!(raw)
      raise Error, "invalid_turn_grant" if raw.blank?

      digest = Assistant::TurnGrant.digest(raw)
      grant = Assistant::TurnGrant.find_by(token_digest: digest)
      unless grant && ActiveSupport::SecurityUtils.secure_compare(grant.token_digest, digest)
        raise Error, "invalid_turn_grant"
      end
      raise Error, "grant_revoked" if grant.revoked_at?
      raise Error, "grant_expired" unless grant.expires_at.future?
      raise Error, "grant_binding_invalid" unless valid_bindings?(grant)

      grant
    end

    def valid_bindings?(grant)
      turn = grant.turn
      turn.user_id == grant.user_id &&
        turn.conversation_id == grant.conversation_id &&
        turn.provider_profile_id == grant.provider_profile_id
    end
    private_class_method :valid_bindings?
  end
end
