module Assistant
  module Grants
    class Authorizer
      RESOURCE_TOOLS = %w[get_selected_context get_artifact_example].freeze

      class Reservation
        def initialize(grant_id:, reserved_bytes:)
          @grant_id = grant_id
          @reserved_bytes = reserved_bytes
          @finished = false
        end

        def complete!(bytes:)
          bytes = Integer(bytes)
          raise ArgumentError, "bytes must be nonnegative" if bytes.negative?
          ensure_open!

          accepted = false
          Assistant::TurnGrant.transaction do
            grant = Assistant::TurnGrant.lock.find(@grant_id)
            release_reservation!(grant)
            rejection_reason = rejection_reason(grant, bytes)

            if rejection_reason
              grant.revoked_at ||= Time.current if rejection_reason == "byte_limit"
              grant.save!
              audit_rejection!(grant, bytes, rejection_reason)
            else
              grant.returned_bytes += bytes
              grant.save!
              accepted = true
            end
          end
          @finished = true
          accepted
        end

        # Accounts the completed write's bytes exactly like #complete!, but
        # never signals a render-rejection: a create that reaches this point
        # already committed its row, so a byte-limit (or other) overrun is
        # recorded for audit/budget bookkeeping without turning the response
        # into a 403 against already-committed state. Callers of a create
        # response must use this instead of #complete!.
        def complete_write!(bytes:)
          bytes = Integer(bytes)
          raise ArgumentError, "bytes must be nonnegative" if bytes.negative?
          ensure_open!

          Assistant::TurnGrant.transaction do
            grant = Assistant::TurnGrant.lock.find(@grant_id)
            release_reservation!(grant)
            rejection_reason = rejection_reason(grant, bytes)

            grant.returned_bytes += bytes
            grant.revoked_at ||= Time.current if rejection_reason == "byte_limit"
            grant.save!

            audit_rejection!(grant, bytes, rejection_reason) if rejection_reason
          end
          @finished = true
          true
        end

        def fail!
          ensure_open!
          Assistant::TurnGrant.transaction do
            grant = Assistant::TurnGrant.lock.find(@grant_id)
            release_reservation!(grant)
            grant.save!
          end
          @finished = true
          true
        end

        private

        def ensure_open!
          raise AuthorizationError, "reservation_consumed" if @finished
        end

        def release_reservation!(grant)
          grant.reserved_bytes = [ grant.reserved_bytes - @reserved_bytes, 0 ].max
        end

        def rejection_reason(grant, bytes)
          return "revoked" if grant.revoked_at?
          return "expired" unless grant.expires_at.future?
          return "byte_limit" if bytes > grant.max_result_bytes

          "byte_limit" if grant.returned_bytes + bytes > grant.max_total_bytes
        end

        def audit_rejection!(grant, bytes, reason)
          Assistant::Audit.record!(
            event: "grant.result_rejected",
            attributes: {
              correlation_id: grant.turn.correlation_id,
              user_id: grant.user_id,
              conversation_id: grant.conversation_id,
              turn_id: grant.turn_id,
              provider_profile_id: grant.provider_profile_id,
              status: "rejected",
              byte_count: bytes,
              metadata: { reason: reason }
            }
          )
        end
      end

      class << self
        def reserve!(raw_grant:, tool:, scope: nil, resource_type: nil, resource_id: nil)
          grant = authenticate!(raw_grant)
          reserved_bytes = nil

          grant.with_lock do
            authorize!(grant, tool.to_s, scope, resource_type, resource_id)
            reserve_budget!(grant)
            reserved_bytes = grant.max_result_bytes
          end

          Reservation.new(grant_id: grant.id, reserved_bytes: reserved_bytes)
        end

        private

        def authenticate!(raw_grant)
          presented_digest = Assistant::TurnGrant.digest(raw_grant)
          grant = Assistant::TurnGrant.find_by(token_digest: presented_digest)
          unless grant && ActiveSupport::SecurityUtils.secure_compare(grant.token_digest, presented_digest)
            raise AuthorizationError, "invalid_grant"
          end

          grant
        end

        def authorize!(grant, tool, scope, resource_type, resource_id)
          raise AuthorizationError, "turn_grant_expired" if grant.revoked_at?
          raise AuthorizationError, "turn_grant_expired" unless grant.expires_at.future?
          raise AuthorizationError, "invalid_turn_grant" unless valid_bindings?(grant)
          raise AuthorizationError, "scope_not_granted" unless grant.tools.include?(tool)
          require_live_capability!(tool)
          if scope.present? && !scope_allowed?(grant, scope.to_s)
            raise AuthorizationError, "scope_not_granted"
          end

          authorize_resource!(grant, tool, resource_type, resource_id)
          raise AuthorizationError, "turn_call_budget_exhausted" if grant.call_count >= grant.max_calls
        end

        def require_live_capability!(tool)
          return if Assistant::Grants::Issuer::LEGACY_TOOLS.include?(tool)

          decision = Assistant::CapabilityPolicy.check(tool: tool)
          raise AuthorizationError, decision.reason unless decision.allowed?
        rescue Assistant::CapabilityCatalog::InvalidCatalog
          raise AuthorizationError, "scope_not_granted"
        end

        def scope_allowed?(grant, scope)
          if Assistant::TurnGrant::READ_SCOPES.include?(scope)
            grant.read_scopes.include?(scope)
          elsif Assistant::TurnGrant::WRITE_SCOPES.include?(scope)
            grant.write_scopes.include?(scope)
          else
            false
          end
        end

        def valid_bindings?(grant)
          turn = grant.turn
          turn.conversation_id == grant.conversation_id &&
            turn.user_id == grant.user_id &&
            turn.provider_profile_id == grant.provider_profile_id
        end

        def authorize_resource!(grant, tool, resource_type, resource_id)
          resource_supplied = resource_type.present? || resource_id.present?
          resource_required = RESOURCE_TOOLS.include?(tool)
          return unless resource_supplied || resource_required

          candidate = { "type" => resource_type.to_s, "id" => resource_id.to_s }
          raise AuthorizationError, "resource_not_allowed" unless grant.resources.include?(candidate)
        end

        def reserve_budget!(grant)
          projected = grant.returned_bytes + grant.reserved_bytes + grant.max_result_bytes
          raise AuthorizationError, "tool_response_rejected" if projected > grant.max_total_bytes

          grant.call_count += 1
          grant.reserved_bytes += grant.max_result_bytes
          grant.save!
        end
      end
    end
  end
end
