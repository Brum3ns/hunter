module Api
  module V1
    module Assistant
      module Machine
        class BaseController < Api::V1::BaseController
          # Machine schemas remain substantially smaller in normal use, but
          # the transport ceiling must match the reviewed per-call ceiling.
          MAX_REQUEST_BYTES = ::Assistant::Config.max_result_bytes

          class_attribute :turn_grant_authorization_required,
            instance_writer: false, default: false

          def self.require_turn_grant_authorization!
            self.turn_grant_authorization_required = true
          end

          skip_before_action :authenticate_api!
          skip_before_action :authorize_scope!
          skip_forgery_protection

          prepend_before_action :machine_response_headers
          prepend_before_action :limit_request_body!
          before_action :authenticate_machine_service!
          before_action :authenticate_machine_authorization!
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

          def authenticate_machine_authorization!
            authorization = if self.class.turn_grant_authorization_required
              ::Assistant::Machine::Authorization.turn_grant!(
                service_identity: Current.assistant_service_identity,
                raw_grant: raw_turn_grant
              )
            else
              ::Assistant::Machine::Authorization.token_only!(
                service_identity: Current.assistant_service_identity
              )
            end
            Current.assistant_machine_authorization = authorization
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
            machine_authorization.grant
          end

          def machine_user
            machine_authorization.user
          end

          def machine_authorization
            Current.assistant_machine_authorization
          end

          def machine_correlation_id
            machine_authorization.correlation_id
          end

          def machine_audit_attributes
            machine_authorization.audit_attributes
          end

          def machine_authorization_subject
            machine_authorization.subject_digest
          end

          def require_control_center_write_enabled!(reservation)
            if !::Assistant::Setting.instance.control_center_write_enabled?
              reservation.fail!
              audit_machine_authoring_failure!(reason: "control_center_write_disabled")
              render json: { error: "control_center_write_disabled" }, status: :forbidden
              return false
            end

            true
          end

          # The create tools already committed the row before this runs, so
          # unlike complete_machine_response! (the read path), this must never
          # turn a committed write into a 403: it accounts the response bytes
          # via Reservation#complete_write! but always renders 201.
          def machine_create_response(reservation, key:, record:)
      machine_authoring_response(reservation, key: key, record: record, status: :created)
      end

      def machine_edit_response(reservation, key:, record:)
      machine_authoring_response(reservation, key: key, record: record, status: :ok)
      end

      def machine_authoring_response(reservation, key:, record:, status:)
            payload = {
              correlation_id: machine_correlation_id,
              key => { id: record.id, name: record.name, lock_version: record.lock_version }
            }
            reservation.complete_write!(bytes: JSON.generate(payload).bytesize)

            set_grant_budget_headers
      render json: payload, status: status
          end

          def render_machine_validation_error(reservation, codes)
            reservation.fail!
            audit_machine_authoring_failure!(reason: "validation_failed")
            render json: { error: "validation_failed", codes: codes }, status: :unprocessable_content
          end

          def render_machine_create_error(reservation, errors)
      render_machine_persist_error(reservation, errors)
      end

      def render_machine_persist_error(reservation, errors)
            reservation.fail!
      if errors.details.values.flatten.any? { |detail| detail[:error] == :taken }
        audit_machine_authoring_failure!(reason: "conflict")
        render json: { error: "conflict" }, status: :conflict
      elsif errors[:base].include?("destination_stale")
        audit_machine_authoring_failure!(reason: "version_conflict")
        render json: { error: "version_conflict" }, status: :conflict
      else
        code = if errors[:variable_set_ids].any?
        "ansible_variable_set_ids_unknown"
        else
        "artifact_persistence_invalid"
        end
        audit_machine_authoring_failure!(reason: "validation_failed")
        render json: { error: "validation_failed", codes: [ code ] }, status: :unprocessable_content
      end
      end

      def render_machine_artifact_not_found(reservation)
      reservation.fail!
      audit_machine_authoring_failure!(reason: "artifact_not_found")
      render json: { error: "not_found" }, status: :not_found
      end

      def consume_authoring_rate!(reservation, action:)
      ::Assistant::RateLimiter.consume!(user: machine_user, action: action)
      true
      rescue ::Assistant::RateLimiter::LimitExceeded => error
      reservation.fail!
      audit_machine_authoring_failure!(reason: "authoring_rate_limited")
      render json: {
        error: "authoring_rate_limited", retry_after: error.retry_after_seconds
      }, status: :too_many_requests
      false
      end

      def machine_expected_lock_version(reservation)
      value = params[:expected_lock_version]
      return value if value.is_a?(Integer) && value >= 0

      render_machine_validation_error(reservation, [ "expected_lock_version_invalid" ])
      nil
      end

          def audit_machine_authoring!(event:, operation:, target_type:, record:)
            attributes = machine_audit_attributes.deep_dup
            attributes.merge!(
              byte_count: request.content_length.to_i,
              target_type: target_type,
              target_id: record.id
            )
            attributes[:metadata].merge!(
              operation: operation,
              outcome: event == "machine.create" ? "created" : "updated"
            )
            ::Assistant::Audit.record!(event: event, attributes: attributes)
          end

          def persist_and_audit_machine_authoring(reservation:, event:, operation:, target_type:)
            result = nil
            ActiveRecord::Base.transaction(requires_new: true) do
              result = yield
              audit_machine_authoring!(event: event, operation: operation,
                target_type: target_type, record: result.record) if result.success?
            end
            result
          rescue StandardError
            reservation.fail!
            raise
          end

          def audit_machine_authoring_failure!(reason:)
            context = machine_authoring_audit_context
            return unless context

            attributes = machine_audit_attributes.deep_dup
            attributes.merge!(
              status: "rejected",
              target_type: context.fetch(:target_type),
              target_id: machine_authoring_target_id
            )
            attributes[:metadata].merge!(
              operation: context.fetch(:operation),
              outcome: "rejected",
              reason: reason.to_s.first(255)
            )
            ::Assistant::Audit.record!(
              event: "machine.#{context.fetch(:action)}_rejected",
              attributes: attributes
            )
          end

          def machine_authoring_audit_context
            case [ controller_path, action_name ]
            when [ "api/v1/assistant/machine/control_center/templates", "create" ]
              { action: "create", operation: "create_whiterabbit_template",
                target_type: "control_center_whiterabbit_template" }
            when [ "api/v1/assistant/machine/control_center/templates", "update" ]
              { action: "edit", operation: "edit_whiterabbit_template",
                target_type: "control_center_whiterabbit_template" }
            when [ "api/v1/assistant/machine/control_center/ansible/playbooks", "create" ]
              { action: "create", operation: "create_ansible_playbook",
                target_type: "control_center_ansible_playbook" }
            when [ "api/v1/assistant/machine/control_center/ansible/playbooks", "update" ]
              { action: "edit", operation: "edit_ansible_playbook",
                target_type: "control_center_ansible_playbook" }
            end
          end

          def machine_authoring_target_id
            value = params[:id].to_s
            value if value.match?(/\A[1-9][0-9]{0,18}\z/)
          end

          def authorize_tool!(tool, scope: nil, resource_type: nil, resource_id: nil)
            ::Assistant::Machine::Authorizer.reserve!(
              authorization: machine_authorization,
              tool: tool,
              scope: scope,
              resource_type: resource_type,
              resource_id: resource_id
            )
          end

          def exact_machine_body(reservation, allowed_keys)
            body = request.request_parameters.to_h.stringify_keys
            unknown = body.keys - Array(allowed_keys).map(&:to_s)
            if unknown.any?
              render_machine_validation_error(reservation, [ "assistant_unknown_input" ])
              return
            end
            body
          end

          def machine_idempotency_key(tool, input)
            canonical = JSON.generate(deep_sort_machine_input(input))
            Digest::SHA256.hexdigest(
              [ machine_authorization_subject, tool, canonical ].join(":")
            )
          end

          def replay_machine_action(reservation, tool:, idempotency_key:)
            receipt = ::Assistant::ActionReceipt.replay(
              authorization: machine_authorization,
              tool: tool,
              idempotency_key: idempotency_key
            )
            return false unless receipt

            complete_machine_effect!(reservation, receipt: receipt, status: :ok)
            true
          end

          def consume_machine_effect!(reservation, launch: false)
            subject = machine_authorization.token_only? ? "token" : machine_grant.turn_id
            action = "#{launch ? 'launch' : 'effect'}:#{subject}"
            ::Assistant::RateLimiter.consume!(user: machine_user, action: action)
            true
          rescue ::Assistant::RateLimiter::LimitExceeded => error
            reservation.fail!
            render json: { error: "effect_rate_limited", retry_after: error.retry_after_seconds },
              status: :too_many_requests
            false
          end

          def issue_machine_receipt(tool:, status:, target_type:, target_id:, idempotency_key:)
            ::Assistant::ActionReceipt.issue!(
              authorization: machine_authorization, tool: tool, status: status,
              target_type: target_type, target_id: target_id,
              idempotency_key: idempotency_key, replayed: false
            )
          end

          def complete_machine_effect!(reservation, receipt:, status: :ok)
            payload = {
              correlation_id: machine_correlation_id,
              receipt: receipt
            }
            reservation.complete_write!(bytes: JSON.generate(payload).bytesize)
            set_grant_budget_headers
            render json: payload, status: status
          end

          def deep_sort_machine_input(value)
            case value
            when Hash
              value.to_h.stringify_keys.sort.to_h do |key, child|
                [ key, deep_sort_machine_input(child) ]
              end
            when Array
              value.map { |child| deep_sort_machine_input(child) }
            else
              value
            end
          end
          private :deep_sort_machine_input

          def complete_machine_response!(reservation, payload, status: :ok)
            bytes = JSON.generate(payload).bytesize
            unless reservation.complete!(bytes: bytes)
              return render json: { error: "tool_response_rejected" }, status: :content_too_large
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
              write_scopes: grant.write_scopes,
              expires_at: grant.expires_at.iso8601,
              calls_remaining: [ grant.max_calls - grant.call_count, 0 ].max,
              bytes_remaining: remaining_bytes(grant)
            }
          end

          def set_grant_budget_headers
            return if machine_authorization.token_only?

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
            code = case error.code
            when "grant_expired", "grant_revoked"
              "turn_grant_expired"
            when "invalid_service_token"
              "invalid_service_token"
            when "invalid_machine_principal"
              "invalid_machine_principal"
            else
              "invalid_turn_grant"
            end
            body = { error: code }
            render json: body, status: status
          end

          def render_grant_authorization_error(error)
            audit_machine_authoring_failure!(reason: error.code) if machine_authoring_audit_context
            code = public_grant_error_code(error.code)
            status = case code
            when "turn_call_budget_exhausted", "effect_rate_limited"
              :too_many_requests
            when "tool_response_rejected"
              :content_too_large
            else
              :forbidden
            end
            render json: { error: code }, status: status
          end

          def public_grant_error_code(code)
            return "scope_not_granted" if code == "resource_not_allowed"
            return code if %w[
              capability_disabled scope_not_granted turn_grant_expired
              turn_call_budget_exhausted effect_rate_limited tool_response_rejected
            ].include?(code)

            "invalid_turn_grant"
          end
        end
      end
    end
  end
end
