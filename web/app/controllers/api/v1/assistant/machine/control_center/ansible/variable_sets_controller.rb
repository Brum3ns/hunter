module Api
  module V1
    module Assistant
      module Machine
        module ControlCenter
          module Ansible
            class VariableSetsController < ReadController
              MAX_LIMIT = 50
              PROJECTION = ::Assistant::Machine::ControlCenter::Ansible::ResourceProjections

              def index
                reservation = authorize_tool!(
                  "list_ansible_variable_sets", scope: "control_center_ansible_variables_read"
                )
                page = machine_page
                limit = machine_limit(MAX_LIMIT)
                scope = ::ControlCenter::Ansible::VariableSet.order(Arel.sql("LOWER(name) ASC"), :id)
                items = scope.offset((page - 1) * limit).limit(limit).map do |set|
                  PROJECTION.variable_set(set, full: false)
                end
                list_response(reservation, count: scope.count, page: page, limit: limit, items: items)
              end

              def show
                reservation = authorize_tool!(
                  "get_ansible_variable_set", scope: "control_center_ansible_variables_read"
                )
                set = find_set
                return machine_not_found(reservation) unless set

                detail_response(reservation, key: :variable_set, value: PROJECTION.variable_set(set, full: true))
              end

              def create
                tool = "create_ansible_variable_set"
                reservation = authorize_tool!(tool, scope: "control_center_ansible_variable_sets_create")
                body = exact_machine_body(reservation, %w[variable_set])
                return unless body
                attributes = variable_set_attributes(body["variable_set"], partial: false)
                return render_machine_validation_error(reservation, [ "ansible_variable_set_invalid" ]) unless attributes
                idempotency_key = machine_idempotency_key(tool, attributes)
                return if replay_machine_action(reservation, tool: tool, idempotency_key: idempotency_key)
                return unless consume_machine_effect!(reservation)

                set = ::ControlCenter::Ansible::VariableSet.new(attributes.merge(created_by: machine_user))
                return render_machine_persist_error(reservation, set.errors) unless set.save
                receipt = issue_machine_receipt(
                  tool: tool, status: "created", target_type: "ansible_variable_set",
                  target_id: set.id, idempotency_key: idempotency_key
                )
                complete_machine_effect!(reservation, receipt: receipt, status: :created)
              end

              def update
                tool = "edit_ansible_variable_set"
                reservation = authorize_tool!(tool, scope: "control_center_ansible_variable_sets_edit")
                body = exact_machine_body(reservation, %w[expected_lock_version changes])
                return unless body
                expected = body["expected_lock_version"]
                unless expected.is_a?(Integer) && expected >= 0
                  return render_machine_validation_error(reservation, [ "expected_lock_version_invalid" ])
                end
                set = find_set
                return machine_not_found(reservation) unless set
                attributes = variable_set_attributes(body["changes"], partial: true)
                return render_machine_validation_error(reservation, [ "ansible_variable_set_invalid" ]) unless attributes
                idempotency_key = machine_idempotency_key(
                  tool, { id: set.id, expected_lock_version: expected, changes: attributes }
                )
                return if replay_machine_action(reservation, tool: tool, idempotency_key: idempotency_key)
                return unless consume_machine_effect!(reservation)
                if set.lock_version != expected
                  reservation.fail!
                  return render json: { error: "version_conflict" }, status: :conflict
                end
                set.assign_attributes(attributes)
                unless set.save
                  return render_machine_persist_error(reservation, set.errors)
                end
                receipt = issue_machine_receipt(
                  tool: tool, status: "updated", target_type: "ansible_variable_set",
                  target_id: set.id, idempotency_key: idempotency_key
                )
                complete_machine_effect!(reservation, receipt: receipt)
              rescue ActiveRecord::StaleObjectError
                reservation.fail!
                render json: { error: "version_conflict" }, status: :conflict
              end

              private

              def find_set
                ::ControlCenter::Ansible::VariableSet.includes(:variables).find_by(id: params[:id])
              end

              def variable_set_attributes(value, partial:)
                raw = value.respond_to?(:to_unsafe_h) ? value.to_unsafe_h : value
                return unless raw.is_a?(Hash)
                input = raw.deep_stringify_keys
                return if (input.keys - %w[name description]).any? || (partial && input.empty?)
                name = input["name"]
                return if (!partial || input.key?("name")) &&
                  !(name.is_a?(String) && name.present? && name.bytesize <= 255)
                description = input["description"]
                return if input.key?("description") && !(
                  description.nil? || (description.is_a?(String) && description.bytesize <= 4_000)
                )
                return unless ::Assistant::Context::SecretDetector.safe?(input)
                input.slice("name", "description").symbolize_keys
              end
            end
          end
        end
      end
    end
  end
end
