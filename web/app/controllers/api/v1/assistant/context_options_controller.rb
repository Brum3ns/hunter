module Api
  module V1
    module Assistant
      class ContextOptionsController < BaseController
        before_action :require_assistant_enabled!

        def index
          options = ::Assistant::Context::Resolver.options(
            type: params.require(:type),
            query: params[:q],
            user: current_assistant_user,
            limit: 20
          )
          safe_options = options.first(20).map do |option|
            option.to_h.symbolize_keys.slice(:type, :id, :label)
          end
          render json: { options: safe_options }
        rescue KeyError
          render json: { error: "unsupported_context_type" }, status: :bad_request
        end
      end
    end
  end
end
