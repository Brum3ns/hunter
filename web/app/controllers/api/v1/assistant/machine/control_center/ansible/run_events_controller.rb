module Api
  module V1
    module Assistant
      module Machine
        module ControlCenter
          module Ansible
            # Read-only, grant-and-scope-gated Ansible run-event browsing for
            # the Assistant. List-only, parented on a required `run_id` query
            # param and cursor-paginated by `after_counter`. Delegates to the
            # same Postgres read path as the public
            # Api::V1::ControlCenter::Ansible::RunEventsController and
            # returns only the bounded RunEventProjection allowlist.
            class RunEventsController < ReadController
              MAX_LIMIT = 100

              def index
                reservation = authorize_tool!("list_run_events", scope: "control_center_ansible_runs_read")
                return machine_not_found(reservation) if params[:run_id].blank?

                page = machine_page
                limit = machine_limit(MAX_LIMIT)
                scope = ::ControlCenter::Ansible::RunEvent.where(run_id: params[:run_id])
                scope = scope.where("counter > ?", params[:after_counter]) if params[:after_counter].present?
                count = scope.count
                rows = scope.order(:counter).limit(limit)
                items = rows.map { |event| ::Assistant::Machine::ControlCenter::Ansible::RunEventProjection.summary(event) }
                list_response(reservation, count: count, page: page, limit: limit, items: items)
              end
            end
          end
        end
      end
    end
  end
end
