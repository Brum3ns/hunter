module Api
  module V1
    # Shared parent for every v1 module API controller (Programs, Vulnerability
    # management, Control center, CVE tracking, ...). Auth / CSRF / JSON / error
    # handling live one level up in Api::BaseController; this layer holds the
    # cross-module conventions — pagination and common responses — so a new
    # module's controller stays thin.
    class BaseController < Api::BaseController
      DEFAULT_LIMIT = 50
      MAX_LIMIT = 200

      private

      def pagination_page
        [params[:page].to_i, 1].max
      end

      def clamped_limit(default: DEFAULT_LIMIT, max: MAX_LIMIT)
        requested = params[:limit].present? ? params[:limit].to_i : default
        requested = default if requested <= 0
        [requested, max].min
      end

      def render_not_found
        render json: { error: "not_found" }, status: :not_found
      end
    end
  end
end
