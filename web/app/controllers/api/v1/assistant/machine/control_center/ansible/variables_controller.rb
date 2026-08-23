module Api
  module V1
    module Assistant
      module Machine
        module ControlCenter
          module Ansible
            class VariablesController < ReadController
              def create
                tool = "create_nonsecret_ansible_variable"
                reservation = authorize_tool!(tool, scope: "control_center_ansible_variables_create")
                body = exact_machine_body(reservation, %w[variable])
                return unless body
                set = find_set
                return machine_not_found(reservation) unless set
                input = input_for(body["variable"])
                return render_machine_validation_error(reservation, input.codes) unless input.valid?
                idempotency_key = machine_idempotency_key(tool, { variable_set_id: set.id, variable: input.attributes })
                return if replay_machine_action(reservation, tool: tool, idempotency_key: idempotency_key)
                return unless consume_machine_effect!(reservation)

                variable = set.variables.build(input.attributes)
                return render_machine_persist_error(reservation, variable.errors) unless variable.save
                receipt = issue_machine_receipt(
                  tool: tool, status: "created", target_type: "ansible_variable",
                  target_id: variable.id, idempotency_key: idempotency_key
                )
                complete_machine_effect!(reservation, receipt: receipt, status: :created)
              end

              def update
                tool = "edit_nonsecret_ansible_variable"
                reservation = authorize_tool!(tool, scope: "control_center_ansible_variables_edit")
                body = exact_machine_body(reservation, %w[expected_lock_version changes])
                return unless body
                expected = body["expected_lock_version"]
                unless expected.is_a?(Integer) && expected >= 0
                  return render_machine_validation_error(reservation, [ "expected_lock_version_invalid" ])
                end
                variable = find_variable
                return machine_not_found(reservation) unless variable
                input = input_for(body["changes"], existing: variable)
                return render_machine_validation_error(reservation, input.codes) unless input.valid?
                idempotency_key = machine_idempotency_key(
                  tool, { id: variable.id, expected_lock_version: expected, changes: input.attributes }
                )
                return if replay_machine_action(reservation, tool: tool, idempotency_key: idempotency_key)
                return unless consume_machine_effect!(reservation)
                if variable.lock_version != expected
                  reservation.fail!
                  return render json: { error: "version_conflict" }, status: :conflict
                end
                variable.assign_attributes(input.attributes)
                return render_machine_persist_error(reservation, variable.errors) unless variable.save
                receipt = issue_machine_receipt(
                  tool: tool, status: "updated", target_type: "ansible_variable",
                  target_id: variable.id, idempotency_key: idempotency_key
                )
                complete_machine_effect!(reservation, receipt: receipt)
              rescue ActiveRecord::StaleObjectError
                reservation.fail!
                render json: { error: "version_conflict" }, status: :conflict
              end

              private

              def find_set
                ::ControlCenter::Ansible::VariableSet.find_by(id: params[:variable_set_id])
              end

              def find_variable
                ::ControlCenter::Ansible::Variable.find_by(
                  id: params[:id], variable_set_id: params[:variable_set_id]
                )
              end

              def input_for(value, existing: nil)
                ::Assistant::Machine::ControlCenter::Ansible::VariableInput.call(value, existing: existing)
              end
            end
          end
        end
      end
    end
  end
end
