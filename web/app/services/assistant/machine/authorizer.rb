module Assistant
  module Machine
    class Authorizer
      class Reservation
        def initialize(authorization:, max_result_bytes:)
          @authorization = authorization
          @max_result_bytes = max_result_bytes
          @finished = false
        end

        def complete!(bytes:)
          bytes = normalized_bytes(bytes)
          ensure_open!
          @finished = true
          return true if bytes <= @max_result_bytes

          audit_rejection!(bytes)
          false
        end

        def complete_write!(bytes:)
          bytes = normalized_bytes(bytes)
          ensure_open!
          @finished = true
          audit_rejection!(bytes) if bytes > @max_result_bytes
          true
        end

        def fail!
          ensure_open!
          @finished = true
          true
        end

        private

        def normalized_bytes(bytes)
          value = Integer(bytes)
          raise ArgumentError, "bytes must be nonnegative" if value.negative?

          value
        end

        def ensure_open!
          raise Assistant::Grants::AuthorizationError, "reservation_consumed" if @finished
        end

        def audit_rejection!(bytes)
          attributes = @authorization.audit_attributes.deep_dup
          attributes[:status] = "rejected"
          attributes[:byte_count] = bytes
          attributes[:metadata][:reason] = "byte_limit"
          Assistant::Audit.record!(event: "machine.result_rejected", attributes: attributes)
        end
      end

      class << self
        def reserve!(authorization:, tool:, scope: nil, resource_type: nil, resource_id: nil)
          return reserve_grant!(authorization, tool, scope, resource_type, resource_id) unless
            authorization.token_only?

          capability = load_capability!(tool)
          unless capability.fetch("scope") == scope.to_s && !scope.to_s.include?("*")
            raise Assistant::Grants::AuthorizationError, "scope_not_granted"
          end

          decision = Assistant::CapabilityPolicy.check(tool: capability.fetch("name"))
          raise Assistant::Grants::AuthorizationError, decision.reason unless decision.allowed?

          Reservation.new(
            authorization: authorization,
            max_result_bytes: Assistant::Config.max_result_bytes
          )
        end

        private

        def load_capability!(tool)
          Assistant::CapabilityCatalog.load.tool!(tool)
        rescue Assistant::CapabilityCatalog::InvalidCatalog
          raise Assistant::Grants::AuthorizationError, "scope_not_granted"
        end

        def reserve_grant!(authorization, tool, scope, resource_type, resource_id)
          Assistant::Grants::Authorizer.reserve!(
            raw_grant: authorization.__send__(:raw_grant),
            tool: tool,
            scope: scope,
            resource_type: resource_type,
            resource_id: resource_id
          )
        end
      end
    end
  end
end
