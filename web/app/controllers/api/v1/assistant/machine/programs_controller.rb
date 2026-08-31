module Api
  module V1
    module Assistant
      module Machine
        # Read-only, grant-and-scope-gated program browsing for the
        # Assistant. Delegates to Programs::Query (list) and Programs::Source
        # (get) — the same Mongo-backed read path the public programs
        # department uses — and returns only the bounded ProgramProjection
        # allowlist, including the favorite/trash/view state of the human user
        # bound to the turn grant.
        class ProgramsController < ReadController
          MAX_LIMIT = 50
          SCALAR_FILTERS = %i[
            status bounty collaboration favorites_only trash_only
            bounty_min_gte bounty_max_gte reports_gte reports_24h_gte reports_7d_gte
            reports_month_gte scope_count_gte scope_count_lte response_lte sort dir
          ].freeze
          ARRAY_FILTERS = %i[platforms scope_types].freeze

          def index
            reservation = authorize_tool!("list_programs", scope: "programs_read")
            page = machine_page
            limit = machine_limit(MAX_LIMIT)
            result = ::Programs::Query.call(query_params(page, limit))
            state = ::Assistant::Machine::ProgramProjection.state_for(machine_user, result.programs.map(&:sid))
            items = result.programs.map do |program|
              ::Assistant::Machine::ProgramProjection.summary(program, state: state)
            end
            list_response(reservation, count: result.total, page: page, limit: limit, items: items)
          end

          def show
            reservation = authorize_tool!("get_program", scope: "programs_read")
            program = ::Programs::Source.find(params[:id])
            return machine_not_found(reservation) unless program

            state = ::Assistant::Machine::ProgramProjection.state_for(machine_user, [ program.sid ])
            detail_response(reservation, key: :program,
              value: ::Assistant::Machine::ProgramProjection.full(program, state: state))
          end

          def analyze
            reservation = authorize_tool!("analyze_programs", scope: "programs_read")
            body = exact_machine_body(
              reservation, [ "q", *SCALAR_FILTERS.map(&:to_s), *ARRAY_FILTERS.map(&:to_s) ]
            )
            return unless body

            params.merge!(body)
            result = ::Programs::Query.call(
              query_params(1, ::Assistant::Machine::WorkflowAnalysis::MAX_ROWS)
            )
            payload = ::Assistant::Machine::WorkflowAnalysis.programs(
              result.programs, count: result.total
            )
            complete_read_response!(reservation,
              { correlation_id: machine_correlation_id }.merge(payload))
          end

          def changes
            reservation = authorize_tool!("list_program_changes", scope: "programs_read")
            page = machine_page
            limit = machine_limit(MAX_LIMIT)
            rows = ::ProgramChange.where(user_id: machine_user.id)
            rows = rows.where(platform: params[:platform]) if params[:platform].present?
            rows = rows.where(kind: params[:kind]) if params[:kind].present?
            rows = rows.where(program_sid: params[:sid]) if params[:sid].present?
            count = rows.count
            items = rows.recent.offset((page - 1) * limit).limit(limit).map(&:as_feed_json)
            list_response(reservation, count: count, page: page, limit: limit, items: items)
          end

          def scope_runs
            reservation = authorize_tool!("list_scope_runs", scope: "programs_read")
            page = machine_page
            limit = machine_limit(MAX_LIMIT)
            rows = filtered_scope_runs
            count = rows.count
            items = rows.recent.offset((page - 1) * limit).limit(limit).map(&:as_log_json)
            list_response(reservation, count: count, page: page, limit: limit, items: items)
          end

          def scope_run
            reservation = authorize_tool!("get_scope_run", scope: "programs_read")
            run = ::ScopeRun.find_by(id: params[:id])
            return machine_not_found(reservation) unless run

            detail_response(reservation, key: :scope_run, value: run.as_log_json)
          end

          private

          def query_params(page, limit)
            parsed = ::Programs::SearchParser.call(params[:q])
            qp = params.permit(*SCALAR_FILTERS).to_h
            ARRAY_FILTERS.each { |name| qp[name] = array_filter(name) }
            qp[:q] = parsed.free_text
            qp[:dork_expression] = parsed.expression
      qp[:_favorited_sids] = machine_user.favorite_sids
      qp[:_trashed_sids] = machine_user.trash_sids
            qp[:page] = page
            qp[:per_page] = limit
            qp
          end

          def filtered_scope_runs
            rows = ::ScopeRun.all
            rows = rows.where(user_id: machine_user.id) if params[:mine].present?
            rows = rows.where(kind: params[:kind]) if params[:kind].present?
            rows = rows.where(platform: params[:platform]) if params[:platform].present?
            rows = rows.where(success: params[:status] == "ok") if params[:status].present?
            rows
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
