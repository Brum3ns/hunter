module Api
  module V1
    module Assistant
      module Machine
        class PoliciesController < BaseController
          def show
            policy = policy_for(params[:artifact_type])
            return render json: { error: "unsupported_type" }, status: :bad_request unless policy

            reservation = authorize_tool!("get_authoring_policy")
            complete_machine_response!(reservation, {
              correlation_id: machine_grant.turn.correlation_id,
              policy: policy
            })
          end

          private

          def policy_for(type)
            ::Assistant::AuthoringPolicy.for(type)
          end
        end
      end
    end
  end
end
