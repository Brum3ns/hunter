module Api
  module V1
    module Assistant
      module Machine
        class ValidationsController < BaseController
          require_turn_grant_authorization!

          VALIDATION_TOOLS = {
            "whiterabbit_template" => "validate_whiterabbit_draft",
            "ansible_playbook" => "validate_ansible_draft"
          }.freeze

          def create
            tool = VALIDATION_TOOLS[params[:artifact_type]]
            return render json: { error: "unsupported_type" }, status: :bad_request unless tool

            reservation = authorize_tool!(tool)
            return validate_whiterabbit(reservation) if params[:artifact_type] == "whiterabbit_template"
            validate_ansible(reservation)
          end

          def show
            reservation = authorize_tool!("get_validation_result")
            validation = ::Assistant::ValidationRequest.find_by(
              id: params[:id], turn_grant_id: machine_grant.id, turn_id: machine_grant.turn_id
            )
            unless validation
              reservation.fail!
              return render json: { error: "validation_not_found" }, status: :not_found
            end

            expire_validation!(validation) if validation.status == "pending" && !validation.expires_at.future?
            stored = validation.result || {}
            normalized = stored["normalized"] && { source: stored["normalized"] }
            complete_machine_response!(reservation, {
              correlation_id: machine_correlation_id,
              validation: validation_payload(
                id: validation.id,
                artifact_type: "ansible_playbook",
                status: validation.status,
                version: stored["validation_version"] || ::Assistant::ValidationDispatcher::VALIDATION_VERSION,
                normalized: normalized,
                content_digest: validation.source_digest,
                codes: stored["codes"] || [],
                messages: stored["messages"] || []
              )
            })
          end

          private

          def validate_whiterabbit(reservation)
            result = ::Assistant::DraftValidation::Whiterabbit.call(params[:draft])
            content = JSON.generate(result.normalized) if result.normalized
            complete_machine_response!(reservation, {
              correlation_id: machine_correlation_id,
              validation: validation_payload(
                id: nil,
                artifact_type: "whiterabbit_template",
                status: result.valid? ? "valid" : "invalid",
                version: result.validation_version,
                normalized: result.normalized,
                content_digest: content && Digest::SHA256.hexdigest(content),
                codes: result.codes,
                messages: result.messages
              )
            })
          end

          def validate_ansible(reservation)
            draft = ::Assistant::DraftEnvelope.ansible(params[:draft])
            unless draft.valid?
              return complete_machine_response!(reservation, {
                correlation_id: machine_correlation_id,
                validation: validation_payload(
                  id: nil, artifact_type: "ansible_playbook", status: "invalid",
                  version: ::Assistant::DraftValidation::AnsibleStatic::VALIDATION_VERSION,
                  normalized: nil, content_digest: nil, codes: draft.codes, messages: draft.messages
                )
              })
            end

            validation_id = ::Assistant::ValidationDispatcher.call(
              turn: machine_grant.turn,
              grant: machine_grant,
              service_identity: Current.assistant_service_identity,
              yaml: draft.normalized.fetch("source")
            )
            validation = ::Assistant::ValidationRequest.find(validation_id)
            complete_machine_response!(reservation, {
              correlation_id: machine_correlation_id,
              validation: validation_payload(
                id: validation.id,
                artifact_type: "ansible_playbook",
                status: "pending",
                version: ::Assistant::ValidationDispatcher::VALIDATION_VERSION,
                normalized: draft.normalized,
                content_digest: validation.source_digest,
                codes: [],
                messages: []
              )
            }, status: :accepted)
          rescue ::Assistant::ValidationDispatcher::InvalidDraft => error
            result = error.result
            complete_machine_response!(reservation, {
              correlation_id: machine_correlation_id,
              validation: validation_payload(
                id: nil,
                artifact_type: "ansible_playbook",
                status: "invalid",
                version: result.validation_version,
                normalized: result.normalized,
                content_digest: nil,
                codes: result.codes,
                messages: result.messages
              )
            })
          rescue ::Assistant::ValidationDispatcher::DispatchFailed
            reservation.fail!
            render json: { error: "validation_unavailable" }, status: :service_unavailable
          rescue ::Assistant::RateLimiter::LimitExceeded => error
            reservation.fail!
            response.headers["Retry-After"] = error.retry_after_seconds.to_s
            render json: { error: error.code }, status: :too_many_requests
          end

          def validation_payload(id:, artifact_type:, status:, version:, normalized:, content_digest:, codes:, messages:)
            {
              id: id,
              artifact_type: artifact_type,
              status: status,
              valid: status == "valid",
              version: version,
              normalized: normalized,
              content_digest: content_digest,
              details: { codes: codes, messages: messages }
            }
          end

          def expire_validation!(validation)
            validation.update!(
              status: "expired",
              source: nil,
              result: {
                "normalized" => nil,
                "codes" => [ "validation_expired" ],
                "messages" => [ "Ansible syntax validation expired." ],
                "validation_version" => ::Assistant::ValidationDispatcher::VALIDATION_VERSION
              },
              completed_at: Time.current
            )
          end
        end
      end
    end
  end
end
