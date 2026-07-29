module Api
  module V1
    module Assistant
      module Machine
        module ControlCenter
          # Read-only, grant-and-scope-gated Whiterabbit job browsing for the
          # Assistant. Delegates to the same Postgres read path as the public
          # Api::V1::ControlCenter::JobsController and returns only the
          # bounded JobProjection allowlist — never template_snapshot,
          # selections, manual_targets, or idempotency_key.
          class JobsController < ReadController
            MAX_LIMIT = 50
            FILTERS = %i[status].freeze

            def index
              reservation = authorize_tool!("list_jobs", scope: "control_center_jobs")
              filters = params.permit(*FILTERS).to_h
              page = machine_page
              limit = machine_limit(MAX_LIMIT)
              scope = filtered_scope(filters)
              count = scope.count
              rows = scope.offset((page - 1) * limit).limit(limit)
              items = rows.map { |job| ::Assistant::Machine::ControlCenter::JobProjection.summary(job) }
              list_response(reservation, count: count, page: page, limit: limit, items: items)
            end

            def show
              reservation = authorize_tool!("get_job", scope: "control_center_jobs")
              job = ::ControlCenter::Job.find_by(id: params[:id])
              return machine_not_found(reservation) unless job

              detail_response(reservation, key: :job, value: ::Assistant::Machine::ControlCenter::JobProjection.full(job))
            end

            private

            def filtered_scope(filters)
              scope = ::ControlCenter::Job.order(created_at: :desc)
              scope = scope.where(status: filters[:status]) if filters[:status].present?
              scope
            end
          end
        end
      end
    end
  end
end
