module Api
  module V1
    module Assistant
      module Machine
        # Read-only, grant-and-scope-gated program browsing for the
        # Assistant. Delegates to Programs::Query (list) and Programs::Source
        # (get) — the same Mongo-backed read path the public programs
        # department uses — and returns only the bounded ProgramProjection
        # allowlist. Machine requests have no Current.user, so favorite/trash
        # filtering is never applied here.
        class ProgramsController < ReadController
          MAX_LIMIT = 50
          SCALAR_FILTERS = %i[status bounty collaboration scope_count_gte scope_count_lte reports_gte sort dir].freeze
          ARRAY_FILTERS = %i[platforms scope_types].freeze

          def index
            reservation = authorize_tool!("list_programs", scope: "programs")
            page = machine_page
            limit = machine_limit(MAX_LIMIT)
            result = ::Programs::Query.call(query_params(page, limit))
            items = result.programs.map { |program| ::Assistant::Machine::ProgramProjection.summary(program) }
            list_response(reservation, count: result.total, page: page, limit: limit, items: items)
          end

          def show
            reservation = authorize_tool!("get_program", scope: "programs")
            program = ::Programs::Source.find(params[:id])
            return machine_not_found(reservation) unless program

            detail_response(reservation, key: :program, value: ::Assistant::Machine::ProgramProjection.full(program))
          end

          private

          def query_params(page, limit)
            parsed = ::Programs::SearchParser.call(params[:q])
            qp = params.permit(*SCALAR_FILTERS).to_h
            ARRAY_FILTERS.each { |name| qp[name] = array_filter(name) }
            qp[:q] = parsed.free_text
            qp[:dork_expression] = parsed.expression
            qp[:page] = page
            qp[:per_page] = limit
            qp
          end

          # platforms/scope_types are array filters in Programs::Query, but
          # the MCP tool schema only accepts scalar strings — accept a real
          # array too (for parity with the public endpoint) and normalize a
          # comma-joined string into the array Programs::Query expects.
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
