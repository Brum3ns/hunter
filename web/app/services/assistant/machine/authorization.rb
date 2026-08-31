require "digest"

module Assistant
  module Machine
    class Authorization
      TOKEN_SUBJECT_DOMAIN = "hunter-assistant-machine-token-only-v1".freeze
      GRANT_SUBJECT_DOMAIN = "hunter-assistant-machine-turn-grant-v1".freeze

      attr_reader :service_identity, :user, :grant, :correlation_id,
        :conversation_id, :turn_id, :provider_profile_id,
        :authorization_mode, :subject_digest

      class << self
        def token_only!(service_identity:)
          require_service_identity!(service_identity)
          user = Assistant::AdminPolicy.configured_user
          raise Assistant::MachineAuthenticator::Error, "invalid_machine_principal" unless user

          new(
            service_identity: service_identity,
            user: user,
            correlation_id: SecureRandom.uuid,
            authorization_mode: "token_only",
            subject_digest: digest_subject(
              TOKEN_SUBJECT_DOMAIN,
              service_identity.id,
              service_identity.token_digest
            )
          )
        end

        def turn_grant!(service_identity:, raw_grant:)
          require_service_identity!(service_identity)
          grant = Assistant::MachineAuthenticator.authenticate_grant!(raw_grant)

          new(
            service_identity: service_identity,
            user: grant.user,
            grant: grant,
            raw_grant: raw_grant,
            correlation_id: grant.turn.correlation_id,
            conversation_id: grant.conversation_id,
            turn_id: grant.turn_id,
            provider_profile_id: grant.provider_profile_id,
            authorization_mode: "turn_grant",
            subject_digest: digest_subject(
              GRANT_SUBJECT_DOMAIN,
              grant.id,
              grant.token_digest
            )
          )
        end

        private

        def require_service_identity!(service_identity)
          valid = service_identity.is_a?(Assistant::ServiceIdentity) &&
            service_identity.enabled? &&
            service_identity.role == Assistant::ServiceIdentity::ROLE_MCP_READER
          raise Assistant::MachineAuthenticator::Error, "invalid_service_token" unless valid
        end

        def digest_subject(domain, id, stored_digest)
          Digest::SHA256.hexdigest([ domain, id, stored_digest ].join("\0"))
        end
      end

      def initialize(
        service_identity:, user:, correlation_id:, authorization_mode:, subject_digest:,
        grant: nil, raw_grant: nil, conversation_id: nil, turn_id: nil,
        provider_profile_id: nil
      )
        @service_identity = service_identity
        @user = user
        @grant = grant
        @raw_grant = raw_grant
        @correlation_id = correlation_id
        @conversation_id = conversation_id
        @turn_id = turn_id
        @provider_profile_id = provider_profile_id
        @authorization_mode = authorization_mode
        @subject_digest = subject_digest
        freeze
      end

      def token_only?
        authorization_mode == "token_only"
      end

      def audit_attributes
        {
          correlation_id: correlation_id,
          user_id: user.id,
          conversation_id: conversation_id,
          turn_id: turn_id,
          provider_profile_id: provider_profile_id,
          metadata: {
            authorization_mode: authorization_mode,
            authorization_subject_digest: subject_digest
          }
        }.compact
      end

      private

      attr_reader :raw_grant
    end
  end
end
