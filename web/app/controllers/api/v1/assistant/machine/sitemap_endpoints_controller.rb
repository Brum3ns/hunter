module Api
  module V1
    module Assistant
      module Machine
        # Read-only, grant-and-scope-gated sitemap endpoint browsing for the
        # Assistant. Delegates to the same Postgres read path as the public
        # Sitemap::EndpointsController (Sitemap::Endpoint.active +
        # Sitemap::EndpointFilter) and returns only the bounded
        # EndpointProjection allowlist.
        class SitemapEndpointsController < ReadController
          MAX_LIMIT = 50
          SCALAR_FILTERS = %i[path has_query content_type].freeze
          ARRAY_FILTERS = %i[methods status].freeze

          def index
            reservation = authorize_tool!("list_endpoints", scope: "sitemap")
            page = machine_page
            limit = machine_limit(MAX_LIMIT)
            scope = filtered_scope
            count = scope.count
            rows = scope.order(:id).offset((page - 1) * limit).limit(limit)
            items = rows.map { |endpoint| ::Assistant::Machine::EndpointProjection.summary(endpoint) }
            list_response(reservation, count: count, page: page, limit: limit, items: items)
          end

          def show
            reservation = authorize_tool!("get_endpoint", scope: "sitemap")
            endpoint = ::Sitemap::Endpoint.active.find_by(id: params[:id])
            return machine_not_found(reservation) unless endpoint

            detail_response(reservation, key: :endpoint, value: ::Assistant::Machine::EndpointProjection.full(endpoint))
          end

          private

          def filtered_scope
            parsed = ::Sitemap::SearchParser.call(params[:q])
            filters = params.permit(*SCALAR_FILTERS).to_h
            ARRAY_FILTERS.each { |name| filters[name] = array_filter(name) }
            ::Sitemap::EndpointFilter.apply(
              ::Sitemap::Endpoint.active, filters,
              free_text: parsed.free_text, expression: parsed.expression
            )
          end

          # methods/status are array filters in Sitemap::EndpointFilter, but the
          # MCP tool schema only accepts scalar strings — accept a real array
          # too (for parity with the public endpoint) and normalize a
          # comma-joined string into the array EndpointFilter expects.
          def array_filter(name)
            raw = params[name]
            return raw.map(&:to_s) if raw.is_a?(Array)

            raw.to_s.split(",").map(&:strip).reject(&:empty?)
          end
        end
      end
    end
  end
end
