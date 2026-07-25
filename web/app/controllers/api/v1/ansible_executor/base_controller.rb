module Api
  module V1
    module AnsibleExecutor
      class BaseController < ActionController::API
        MAX_BODY_BYTES = 1.megabyte
        LEASE_HEADER = "X-Ansible-Lease"
        BEARER_PATTERN = /\ABearer ([A-Za-z0-9_-]{32,512})\z/

        before_action :enforce_body_limit!
        before_action :authenticate_executor!

        rescue_from ::ControlCenter::Ansible::LeaseVerifier::Conflict, with: :render_protocol_error
        rescue_from ::ControlCenter::Ansible::RunEventIngestor::Error, with: :render_protocol_error
        rescue_from ::ControlCenter::Ansible::RunResult::Error, with: :render_protocol_error
        rescue_from ::ControlCenter::Ansible::ExecutorTaskResult::Error, with: :render_protocol_error

        private

        def enforce_body_limit!
          return unless request.content_length.to_i > MAX_BODY_BYTES

          render json: { error: "payload_too_large" }, status: 413
        end

        def authenticate_executor!
          match = BEARER_PATTERN.match(request.authorization.to_s)
          runner = match && ::Runner.authenticate(match[1])
          return render(json: { error: "unauthorized" }, status: :unauthorized) unless runner
          unless runner.kinds.include?("ansible")
            return render json: { error: "insufficient_capability" }, status: :forbidden
          end

          Current.runner = runner
        end

        def lease_token
          request.headers[LEASE_HEADER].to_s
        end

        def lease_seconds
          Integer(ENV.fetch("ANSIBLE_LEASE_SECONDS", "45"), 10)
        end

        def render_not_found
          render json: { error: "not_found" }, status: :not_found
        end

        def render_protocol_error(error)
          conflict = error.is_a?(::ControlCenter::Ansible::LeaseVerifier::Conflict) ||
            error.code.in?(%w[event_conflict result_conflict])
          render json: { error: error.code, detail: error.message },
            status: conflict ? :conflict : :unprocessable_entity
        end
      end
    end
  end
end
