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
              reservation = authorize_tool!("list_jobs", scope: "control_center_jobs_read")
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
              reservation = authorize_tool!("get_job", scope: "control_center_jobs_read")
              job = ::ControlCenter::Job.find_by(id: params[:id])
              return machine_not_found(reservation) unless job

              detail_response(reservation, key: :job, value: ::Assistant::Machine::ControlCenter::JobProjection.full(job))
            end

            def analyze
              reservation = authorize_tool!("analyze_jobs", scope: "control_center_jobs_read")
              body = exact_machine_body(reservation, %w[status])
              return unless body
              scope = filtered_scope(body)
              count = scope.count
              rows = scope.limit(::Assistant::Machine::WorkflowAnalysis::MAX_ROWS).to_a
              payload = ::Assistant::Machine::WorkflowAnalysis.jobs(rows, count: count)
              complete_read_response!(reservation,
                { correlation_id: machine_grant.turn.correlation_id }.merge(payload))
            end

            def resolve_targets
              reservation = authorize_tool!("resolve_job_targets", scope: "control_center_jobs_read")
              input = ::Assistant::Machine::ControlCenter::JobInput.call(
                request.request_parameters, require_template: false
              )
              return render_machine_validation_error(reservation, input.codes) unless input.success?
              attrs = input.attributes
              ::ControlCenter::TargetSelection.validate!(attrs.fetch("selections"))
              payload = {
                correlation_id: machine_grant.turn.correlation_id,
                count: ::ControlCenter::TargetSelection.count(
                  attrs.fetch("selections"), attrs.fetch("targets")
                ),
                truncated: false,
                sample: ::ControlCenter::TargetSelection.sample(
                  attrs.fetch("selections"), attrs.fetch("targets"), limit: 50
                )
              }
              complete_read_response!(reservation, payload)
            rescue ::ControlCenter::TargetSelection::InvalidSelection
              render_machine_validation_error(reservation, [ "assistant_job_selections_invalid" ])
            end

            def create
              tool = "submit_whiterabbit_job"
              reservation = authorize_tool!(tool, scope: "control_center_jobs_submit")
              input = ::Assistant::Machine::ControlCenter::JobInput.call(
                request.request_parameters, require_template: true
              )
              return render_machine_validation_error(reservation, input.codes) unless input.success?
              attrs = input.attributes
              template = ::ControlCenter::Template.find_by(name: attrs.fetch("template"))
              unless template
                reservation.fail!
                return render json: { error: "not_found" }, status: :not_found
              end
              errors = ::ControlCenter::TemplateValidator.call(template.commands)
              return render_machine_validation_error(reservation, errors) if errors.any?
              ::ControlCenter::TargetSelection.validate!(attrs.fetch("selections"))

              idempotency_key = machine_idempotency_key(tool, attrs)
              return if replay_machine_action(reservation, tool: tool, idempotency_key: idempotency_key)
              return unless consume_machine_effect!(reservation, launch: true)

              job = ::ControlCenter::Job.create!(
                template_name: template.name,
                template_snapshot: ::ControlCenter::TemplateRenderer.to_hash(template),
                queue_name: attrs.fetch("queue_name"),
                selections: attrs.fetch("selections"), manual_targets: attrs.fetch("targets"),
                target_chunk: attrs.fetch("target_chunk"), job_delay_ms: attrs.fetch("delay"),
                target_count: 0, status: "queued", idempotency_key: idempotency_key,
                created_by: machine_user.username
              )
              ::ControlCenter::SubmitJob.perform_later(job.id)
              receipt = issue_machine_receipt(
                tool: tool, status: "submitted", target_type: "whiterabbit_job",
                target_id: job.id, idempotency_key: idempotency_key
              )
              complete_machine_effect!(reservation, receipt: receipt, status: :created)
            rescue ::ControlCenter::TargetSelection::InvalidSelection
              render_machine_validation_error(reservation, [ "assistant_job_selections_invalid" ])
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
