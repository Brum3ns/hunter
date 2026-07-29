module Api
  module V1
    module Assistant
      module Machine
        module ControlCenter
          module Ansible
            # Read-only, grant-and-scope-gated Ansible run browsing for the
            # Assistant. Get-only — listing runs happens via a parent
            # get_run_group. Delegates to the same Postgres read path as the
            # public Api::V1::ControlCenter::Ansible::RunsController and
            # returns only the bounded RunProjection allowlist — never
            # `playbook_yaml`, `inventory_yaml`, `known_hosts`,
            # `lease_digest`, or `runner_id`.
            class RunsController < ReadController
              def show
                reservation = authorize_tool!("get_run", scope: "control_center_ansible")
                run = ::ControlCenter::Ansible::Run.find_by(id: params[:id])
                return machine_not_found(reservation) unless run

                detail_response(
                  reservation, key: :run,
                  value: ::Assistant::Machine::ControlCenter::Ansible::RunProjection.full(run)
                )
              end
            end
          end
        end
      end
    end
  end
end
