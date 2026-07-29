module Api
  module V1
    module Assistant
      module Machine
        module ControlCenter
          module Ansible
            # Read-only, grant-and-scope-gated Ansible run-group browsing for
            # the Assistant. Delegates to the same Postgres read path as the
            # public Api::V1::ControlCenter::Ansible::RunGroupsController and
            # returns only the bounded RunGroupProjection allowlist — never
            # `execution_payload` (encrypted, resolved secrets).
            class RunGroupsController < ReadController
              MAX_LIMIT = 50

              def index
                reservation = authorize_tool!("list_run_groups", scope: "control_center_ansible")
                page = machine_page
                limit = machine_limit(MAX_LIMIT)
                scope = ::ControlCenter::Ansible::RunGroup.order(created_at: :desc)
                count = scope.count
                rows = scope.offset((page - 1) * limit).limit(limit)
                items = rows.map { |group| ::Assistant::Machine::ControlCenter::Ansible::RunGroupProjection.summary(group) }
                list_response(reservation, count: count, page: page, limit: limit, items: items)
              end

              def show
                reservation = authorize_tool!("get_run_group", scope: "control_center_ansible")
                group = ::ControlCenter::Ansible::RunGroup.includes(:runs).find_by(id: params[:id])
                return machine_not_found(reservation) unless group

                detail_response(
                  reservation, key: :run_group,
                  value: ::Assistant::Machine::ControlCenter::Ansible::RunGroupProjection.full(group)
                )
              end
            end
          end
        end
      end
    end
  end
end
