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
                reservation = authorize_tool!("get_run", scope: "control_center_ansible_runs_read")
                run = ::ControlCenter::Ansible::Run.find_by(id: params[:id])
                return machine_not_found(reservation) unless run

                detail_response(
                  reservation, key: :run,
                  value: ::Assistant::Machine::ControlCenter::Ansible::RunProjection.full(run)
                )
              end

              def cancel
                tool = "cancel_ansible_run"
                reservation = authorize_tool!(tool, scope: "control_center_ansible_runs_cancel")
                body = exact_machine_body(reservation, [])
                return unless body
                run = ::ControlCenter::Ansible::Run.find_by(id: params[:id])
                return machine_not_found(reservation) unless run
                idempotency_key = machine_idempotency_key(tool, { id: run.id })
                return if replay_machine_action(reservation, tool: tool, idempotency_key: idempotency_key)
                return unless consume_machine_effect!(reservation, launch: true)
                ::ControlCenter::Ansible::RunCancellation.cancel_run!(run)
                receipt = issue_machine_receipt(
                  tool: tool, status: "cancelled", target_type: "ansible_run",
                  target_id: run.id, idempotency_key: idempotency_key
                )
                complete_machine_effect!(reservation, receipt: receipt)
              rescue ::ControlCenter::Ansible::RunCancellation::Conflict
                reservation.fail!
                render json: { error: "conflict" }, status: :conflict
              end
            end
          end
        end
      end
    end
  end
end
