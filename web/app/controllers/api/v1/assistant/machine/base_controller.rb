module Api
  module V1
    module Assistant
      module Machine
        class BaseController < Api::V1::BaseController
          MAX_REQUEST_BYTES = 65_536

          skip_before_action :authenticate_api!
          skip_before_action :authorize_scope!
          skip_forgery_protection

          prepend_before_action :machine_response_headers
          prepend_before_action :limit_request_body!
          before_action :authenticate_machine_service!
          before_action :authenticate_turn_grant!
          before_action :require_machine_assistant_enabled!

          rescue_from ::Assistant::MachineAuthenticator::Error, with: :render_machine_auth_error
          rescue_from ::Assistant::Grants::AuthorizationError, with: :render_grant_authorization_error

          private

          def machine_response_headers
            response.headers["Cache-Control"] = "no-store"
          end

          def limit_request_body!
            return unless request.post? || request.put? || request.patch?
            return if request.content_length.to_i <= MAX_REQUEST_BYTES

            render json: { error: "request_too_large" }, status: :content_too_large
          end

          def authenticate_machine_service!
            raise ::Assistant::MachineAuthenticator::Error, "invalid_service_token" if
              cookies.signed[:session_id].present?

            Current.assistant_service_identity = ::Assistant::MachineAuthenticator.authenticate_service!(
              machine_bearer_token
            )
          end

          def authenticate_turn_grant!
            Current.assistant_turn_grant = ::Assistant::MachineAuthenticator.authenticate_grant!(
              raw_turn_grant
            )
          end

          def require_machine_assistant_enabled!
            return if ::Assistant::Config.enabled? && ::Assistant::Setting.instance.assistant_enabled?

            render json: { error: "assistant_disabled" }, status: :service_unavailable
          end

          def machine_bearer_token
            match = request.authorization.to_s.match(/\ABearer\s+(\S+)\z/)
            match && match[1]
          end

          def raw_turn_grant
            request.headers["X-Hunter-Turn-Grant"].to_s.presence
          end

          def machine_grant
            Current.assistant_turn_grant
          end

          def authorize_tool!(tool, scope: nil, resource_type: nil, resource_id: nil)
            ::Assistant::Grants::Authorizer.reserve!(
              raw_grant: raw_turn_grant,
              tool: tool,
              scope: scope,
              resource_type: resource_type,
              resource_id: resource_id
            )
          end

          def complete_machine_response!(reservation, payload, status: :ok)
            bytes = JSON.generate(payload).bytesize
            unless reservation.complete!(bytes: bytes)
              return render json: { error: "result_rejected" }, status: :forbidden
            end

            set_grant_budget_headers
            render json: payload, status: status
          end

          def grant_scope_payload
            grant = machine_grant.reload
            {
              grant_id: grant.id,
              correlation_id: grant.turn.correlation_id,
              tools: grant.tools,
              resources: grant.resources,
              read_scopes: grant.read_scopes,
              expires_at: grant.expires_at.iso8601,
              calls_remaining: [ grant.max_calls - grant.call_count, 0 ].max,
              bytes_remaining: remaining_bytes(grant)
            }
          end

          def set_grant_budget_headers
            grant = machine_grant.reload
            response.headers["X-Hunter-Grant-Calls-Remaining"] =
              [ grant.max_calls - grant.call_count, 0 ].max.to_s
            response.headers["X-Hunter-Grant-Bytes-Remaining"] = remaining_bytes(grant).to_s
          end

          def remaining_bytes(grant)
            [ grant.max_total_bytes - grant.returned_bytes - grant.reserved_bytes, 0 ].max
          end

          def render_machine_auth_error(error)
            status = error.code == "invalid_service_token" ? :unauthorized : :forbidden
            body = if error.code == "invalid_service_token"
              { error: "invalid_service_token" }
            else
              { error: "invalid_turn_grant", reason: error.code }
            end
            render json: body, status: status
          end

          def render_grant_authorization_error(error)
            render json: { error: "invalid_turn_grant", reason: error.code }, status: :forbidden
          end
        end
      end
    end
  end
end
