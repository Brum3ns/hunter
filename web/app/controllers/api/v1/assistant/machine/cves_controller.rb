module Api
  module V1
    module Assistant
      module Machine
        # Read-only, grant-and-scope-gated CVE browsing for the Assistant.
        # Delegates to Cves::MongoSource (public OSV data) and returns only the
        # bounded CveProjection allowlist.
        class CvesController < ReadController
          MAX_LIMIT = 50
          FILTERS = %i[ecosystem package language vendor cwe tag has_fix min_severity published_after modified_after].freeze

          def index
            reservation = authorize_tool!("list_cves", scope: "cves")
            filters = params.permit(*FILTERS).to_h
            search = params[:q].presence
            page = machine_page
            limit = machine_limit(MAX_LIMIT)
            count = ::Cves::MongoSource.count(filters: filters, search: search)
            items = ::Cves::MongoSource.all(filters: filters, search: search, page: page, limit: limit)
                                       .map { |doc| ::Assistant::Machine::CveProjection.summary(::Cve.new(doc)) }
            list_response(reservation, count: count, page: page, limit: limit, items: items)
          end

          def show
            reservation = authorize_tool!("get_cve", scope: "cves")
            doc = ::Cves::MongoSource.find(params[:id])
            return machine_not_found(reservation) unless doc

            detail_response(reservation, key: :cve, value: ::Assistant::Machine::CveProjection.full(::Cve.new(doc)))
          end
        end
      end
    end
  end
end
