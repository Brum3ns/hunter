module Api
  module V1
    module Assistant
      module Machine
        module ControlCenter
          # Read-only, grant-and-scope-gated Whiterabbit template browsing for
          # the Assistant. Delegates to the same Postgres read path as the
          # public Api::V1::ControlCenter::TemplatesController and returns
          # only the bounded TemplateProjection allowlist.
          class TemplatesController < ReadController
            MAX_LIMIT = 50
            FILTERS = %i[kind].freeze

            def index
              reservation = authorize_tool!("list_templates", scope: "control_center_templates")
              filters = params.permit(*FILTERS).to_h
              page = machine_page
              limit = machine_limit(MAX_LIMIT)
              scope = filtered_scope(filters)
              count = scope.count
              rows = scope.offset((page - 1) * limit).limit(limit)
              items = rows.map { |template| ::Assistant::Machine::ControlCenter::TemplateProjection.summary(template) }
              list_response(reservation, count: count, page: page, limit: limit, items: items)
            end

            def show
              reservation = authorize_tool!("get_template", scope: "control_center_templates")
              template = ::ControlCenter::Template.find_by(id: params[:id])
              return machine_not_found(reservation) unless template

              detail_response(reservation, key: :template, value: ::Assistant::Machine::ControlCenter::TemplateProjection.full(template))
            end

            # Approval-free create. DraftValidation is the sole, fail-closed
            # persist gate below — it MUST run and MUST reject (422, no
            # persist) before ControlCenter::Templates::Persist is ever
            # called. Create-only: always ControlCenter::Template.new, never
            # an existing record; a duplicate name is rejected by Persist
            # (422), never overwritten.
            def create
              reservation = authorize_tool!("create_whiterabbit_template", scope: "control_center_templates_write")
              return unless require_control_center_write_enabled!(reservation)

              begin
                ::Assistant::RateLimiter.consume!(user: machine_user, action: "create")
              rescue ::Assistant::RateLimiter::LimitExceeded => e
                reservation.fail!
                return render json: { error: e.code, retry_after: e.retry_after_seconds }, status: :too_many_requests
              end

              result = ::Assistant::DraftValidation::Whiterabbit.call(params[:template])
              return render_machine_validation_error(reservation, result.codes) unless result.valid?

              persist = ::ControlCenter::Templates::Persist.call(
                record: ::ControlCenter::Template.new, attributes: result.normalized, user: machine_user
              )
              return render_machine_create_error(reservation, persist.errors) unless persist.success?

              ::Assistant::Audit.record!(event: "machine.create", attributes: {
                correlation_id: machine_grant.turn.correlation_id, user_id: machine_user&.id,
                target_type: "control_center_whiterabbit_template", target_id: persist.record.id,
                metadata: { operation: "create_whiterabbit_template", outcome: "created" }
              })
              machine_create_response(reservation, key: :template, record: persist.record)
            end

            private

            def filtered_scope(filters)
              scope = ::ControlCenter::Template.order(:name)
              scope = scope.where(kind: filters[:kind]) if filters[:kind].present?
              scope
            end
          end
        end
      end
    end
  end
end
