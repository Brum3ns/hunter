module Api
  module V1
    module Assistant
      module Machine
        # Read-only, grant-and-scope-gated vulnerability browsing for the
        # Assistant. Delegates to Vulnerabilities::MongoSource and returns
        # only the bounded VulnerabilityProjection allowlist — the hard
        # secret-exclusion boundary (raw request/response HTTP, poc curl/
        # extracted/llm_reasoning, operator PII) lives in that projection.
        class VulnerabilitiesController < ReadController
          MAX_LIMIT = 50
          FILTERS = %i[program severity status tool].freeze

          def index
            reservation = authorize_tool!("list_vulnerabilities", scope: "vulnerabilities")
            filters = params.permit(*FILTERS).to_h
            search = params[:q].presence
            page = machine_page
            limit = machine_limit(MAX_LIMIT)
            count = ::Vulnerabilities::MongoSource.count(filters: filters, search: search)
            items = ::Vulnerabilities::MongoSource.all(filters: filters, search: search, page: page, limit: limit)
                                                   .map { |vuln| ::Assistant::Machine::VulnerabilityProjection.summary(vuln) }
            list_response(reservation, count: count, page: page, limit: limit, items: items)
          end

          def show
            reservation = authorize_tool!("get_vulnerability", scope: "vulnerabilities")
            vuln = ::Vulnerabilities::MongoSource.find(params[:id])
            return machine_not_found(reservation) unless vuln

            detail_response(reservation, key: :vulnerability, value: ::Assistant::Machine::VulnerabilityProjection.full(vuln))
          end
        end
      end
    end
  end
end
