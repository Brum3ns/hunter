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
            reservation = authorize_tool!("list_cves", scope: "cves_read")
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
            reservation = authorize_tool!("get_cve", scope: "cves_read")
            doc = ::Cves::MongoSource.find(params[:id])
            return machine_not_found(reservation) unless doc

            detail_response(reservation, key: :cve, value: ::Assistant::Machine::CveProjection.full(::Cve.new(doc)))
          end

          def new
            reservation = authorize_tool!("list_new_cves", scope: "cves_read")
            limit = machine_limit(MAX_LIMIT)
            since = Time.iso8601(params[:since].to_s) if params[:since].present?
            filters = params.permit(*FILTERS).to_h
            docs = ::Cves::MongoSource.new_since(
              since: since, since_id: params[:since_id].presence, limit: limit,
              filters: filters, search: params[:q].presence
            )
            items = docs.map { |doc| ::Assistant::Machine::CveProjection.summary(::Cve.new(doc)) }
            complete_read_response!(reservation, {
              correlation_id: machine_correlation_id,
              count: items.length,
              limit: limit,
              items: items,
              next_since: docs.last && docs.last["first_seen_at"],
              next_since_id: docs.last && docs.last["id"]
            })
          rescue ArgumentError
            render_machine_validation_error(reservation, [ "assistant_since_invalid" ])
          end

          def analyze
            reservation = authorize_tool!("analyze_cves", scope: "cves_read")
            body = exact_machine_body(reservation, [ "q", *FILTERS.map(&:to_s) ])
            return unless body

            filters = body.except("q")
            count = ::Cves::MongoSource.count(filters: filters, search: body["q"].presence)
            docs = ::Cves::MongoSource.all(
              filters: filters, search: body["q"].presence, page: 1,
              limit: ::Assistant::Machine::WorkflowAnalysis::MAX_ROWS
            )
            payload = ::Assistant::Machine::WorkflowAnalysis.cves(
              docs.map { |doc| ::Cve.new(doc) }, count: count
            )
            complete_read_response!(reservation,
              { correlation_id: machine_correlation_id }.merge(payload))
          end
        end
      end
    end
  end
end
