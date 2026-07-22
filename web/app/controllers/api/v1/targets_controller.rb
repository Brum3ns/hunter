module Api
  module V1
    # Target module API — read-only list + detail over the MongoDB `alive`
    # collection. Shares the service layer with the web department.
    class TargetsController < BaseController
      # GET /api/v1/targets
      def index
        filters = filter_params
        parsed  = Targets::SearchParser.call(params[:q])
        search  = parsed.free_text.presence
        expr    = parsed.expression
        page    = pagination_page
        limit   = clamped_limit

        docs = Targets::MongoSource.all(
          filters: filters, search: search, expression: expr,
          sort: params[:sort], dir: params[:dir],
          page: page, limit: limit
        )
        render json: {
          count: Targets::MongoSource.count(filters: filters, search: search, expression: expr),
          page: page,
          limit: limit,
          targets: docs.map { |doc| Target.new(doc).as_json }
        }
      end

      # GET /api/v1/targets/:id
      def show
        doc = Targets::MongoSource.find(params[:id])
        return render_not_found unless doc

        render json: Target.new(doc).as_json
      end

      private

      def filter_params
        params.permit(:program, :status).to_h
      end
    end
  end
end
