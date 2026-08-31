module Api
  module V1
    module Assistant
      module Machine
        class ContextsController < BaseController
          require_turn_grant_authorization!

          def show
            reservation = authorize_tool!(
              "get_selected_context",
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

            context = ::Assistant::Context::Catalog.serialize!(
              type: params[:resource_type], record: record
            )
            complete_machine_response!(reservation, {
              correlation_id: machine_correlation_id,
              context: context
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
