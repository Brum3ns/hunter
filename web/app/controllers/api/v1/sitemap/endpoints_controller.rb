module Api
  module V1
    module Sitemap
      # Read-only list of crawled endpoints for target selection. Mirrors the
      # Targets API: paginated envelope, same dork/free-text `q` as the sitemap
      # web page. Read failures degrade to an empty page (never 502 here).
      class EndpointsController < Api::V1::BaseController
        api_scope :sitemap

        def index
          page  = pagination_page
          limit = clamped_limit
          scope = filtered_scope
          total = scope.count
          rows  = scope.order(:id).offset((page - 1) * limit).limit(limit)
          render json: {
            endpoints: rows.map { |e| serialize(e) },
            page: page, limit: limit, total: total
          }
        rescue ActiveRecord::StatementInvalid => e
          Rails.logger.warn("Sitemap endpoints index failed: #{e.message}")
          render json: { endpoints: [], page: page, limit: limit, total: 0 }
        end

        private

        def filtered_scope
          parsed = ::Sitemap::SearchParser.call(params[:q])
          ::Sitemap::EndpointFilter.apply(
            ::Sitemap::Endpoint.active,
            params.permit(:path, :has_query, :content_type, methods: [], status: []),
            free_text: parsed.free_text, expression: parsed.expression
          )
        end

        def serialize(e)
          { id: e.id, url: e.url, path: e.path, method: e.read_attribute(:method), status_code: e.status_code }
        end
      end
    end
  end
end
