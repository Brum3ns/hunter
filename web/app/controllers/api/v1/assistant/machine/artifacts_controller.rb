module Api
  module V1
    module Assistant
      module Machine
        class ArtifactsController < BaseController
          require_turn_grant_authorization!

          ARTIFACT_TYPES = %w[whiterabbit_template ansible_playbook].freeze

          def show
            return render json: { error: "unsupported_type" }, status: :bad_request unless
              ARTIFACT_TYPES.include?(params[:resource_type])

            reservation = authorize_tool!(
              "get_artifact_example",
              resource_type: params[:resource_type],
              resource_id: params[:id]
            )
            record = ::Assistant::Context::Resolver.find(
              type: params[:resource_type], id: params[:id], user: machine_grant.user
            )
            unless record
              reservation.fail!
              return render json: { error: "not_found" }, status: :not_found
            end

            artifact = ::Assistant::Context::Catalog.serialize!(
              type: params[:resource_type], record: record
            )
            complete_machine_response!(reservation, {
              correlation_id: machine_correlation_id,
              artifact: artifact
            })
          rescue ::Assistant::Context::Catalog::UnsafeContentError
            reservation&.fail!
            render json: { error: "unsafe_content" }, status: :unprocessable_entity
          rescue ::Assistant::Context::Catalog::TooLargeError
            reservation&.fail!
            render json: { error: "result_too_large" }, status: :content_too_large
          end
        end
      end
    end
  end
end
