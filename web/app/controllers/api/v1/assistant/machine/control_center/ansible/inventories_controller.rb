module Api
  module V1
    module Assistant
      module Machine
        module ControlCenter
          module Ansible
            class InventoriesController < ReadController
              MAX_LIMIT = 50
              PROJECTION = ::Assistant::Machine::ControlCenter::Ansible::ResourceProjections

              def index
                reservation = authorize_tool!(
                  "list_ansible_inventories", scope: "control_center_ansible_inventories_read"
                )
                page = machine_page
                limit = machine_limit(MAX_LIMIT)
                scope = ::ControlCenter::Ansible::Inventory.includes(:variable_sets).order(:name)
                items = scope.offset((page - 1) * limit).limit(limit).map do |inventory|
                  PROJECTION.inventory(inventory, full: false)
                end
                list_response(reservation, count: scope.count, page: page, limit: limit, items: items)
              end

              def show
                reservation = authorize_tool!(
                  "get_ansible_inventory", scope: "control_center_ansible_inventories_read"
                )
                inventory = find_inventory
                return machine_not_found(reservation) unless inventory

                detail_response(reservation, key: :inventory, value: PROJECTION.inventory(inventory, full: true))
              end

              def validate
                reservation = authorize_tool!(
                  "validate_ansible_inventory", scope: "control_center_ansible_inventories_read"
                )
                body = exact_machine_body(reservation, %w[yaml_content])
                return unless body
                input = ::Assistant::Machine::ControlCenter::Ansible::InventoryInput.call(
                  { "name" => "validation", "yaml_content" => body["yaml_content"] }, partial: false
                )
                complete_read_response!(reservation, {
                  correlation_id: machine_correlation_id,
                  valid: input.valid?, codes: input.codes
                })
              end

              def create
                tool = "create_ansible_inventory"
                reservation = authorize_tool!(tool, scope: "control_center_ansible_inventories_create")
                body = exact_machine_body(reservation, %w[inventory])
                return unless body
                input = ::Assistant::Machine::ControlCenter::Ansible::InventoryInput.call(
                  body["inventory"], partial: false
                )
                return render_machine_validation_error(reservation, input.codes) unless input.valid?
                resources = resolve_resources(input)
                return render_machine_validation_error(reservation, [ "ansible_inventory_reference_invalid" ]) unless resources

                idempotency_key = machine_idempotency_key(tool, body.fetch("inventory"))
                return if replay_machine_action(reservation, tool: tool, idempotency_key: idempotency_key)
                return unless consume_machine_effect!(reservation)
                inventory = persist_inventory(
                  ::ControlCenter::Ansible::Inventory.new(created_by: machine_user), input, resources
                )
                return render_machine_validation_error(reservation, [ "ansible_inventory_invalid" ]) unless inventory
                receipt = issue_machine_receipt(
                  tool: tool, status: "created", target_type: "ansible_inventory",
                  target_id: inventory.id, idempotency_key: idempotency_key
                )
                complete_machine_effect!(reservation, receipt: receipt, status: :created)
              end

              def update
                tool = "edit_ansible_inventory"
                reservation = authorize_tool!(tool, scope: "control_center_ansible_inventories_edit")
                body = exact_machine_body(reservation, %w[expected_lock_version changes])
                return unless body
                expected = body["expected_lock_version"]
                unless expected.is_a?(Integer) && expected >= 0
                  return render_machine_validation_error(reservation, [ "expected_lock_version_invalid" ])
                end
                inventory = find_inventory
                return machine_not_found(reservation) unless inventory
                input = ::Assistant::Machine::ControlCenter::Ansible::InventoryInput.call(
                  body["changes"], partial: true
                )
                return render_machine_validation_error(reservation, input.codes) unless input.valid?
                resources = resolve_resources(input)
                return render_machine_validation_error(reservation, [ "ansible_inventory_reference_invalid" ]) unless resources
                idempotency_key = machine_idempotency_key(tool,
                  { id: inventory.id, expected_lock_version: expected, changes: body["changes"] })
                return if replay_machine_action(reservation, tool: tool, idempotency_key: idempotency_key)
                return unless consume_machine_effect!(reservation)
                if inventory.lock_version != expected
                  reservation.fail!
                  return render json: { error: "version_conflict" }, status: :conflict
                end
                inventory = persist_inventory(inventory, input, resources)
                unless inventory
                  reservation.fail!
                  return render json: { error: "version_conflict" }, status: :conflict
                end
                receipt = issue_machine_receipt(
                  tool: tool, status: "updated", target_type: "ansible_inventory",
                  target_id: inventory.id, idempotency_key: idempotency_key
                )
                complete_machine_effect!(reservation, receipt: receipt)
              end

              def syntax_check
                queue_utility(
                  tool: "queue_inventory_syntax_check",
                  scope: "control_center_ansible_inventory_syntax_check",
                  allowed: %w[playbook_id]
                ) do |inventory, body|
                  playbook = ::ControlCenter::Ansible::Playbook.find_by(id: body["playbook_id"])
                  raise ActiveRecord::RecordNotFound unless playbook
                  ::ControlCenter::Ansible::ExecutorTaskBuilder.syntax_check(
                    user: machine_user, inventory: inventory, playbook: playbook
                  )
                end
              end

              def host_key_scan
                queue_utility(
                  tool: "queue_host_key_scan",
                  scope: "control_center_ansible_inventory_host_key_scan", allowed: []
                ) do |inventory, _body|
                  ::ControlCenter::Ansible::ExecutorTaskBuilder.host_key_scan(
                    user: machine_user, inventory: inventory
                  )
                end
              end

              def connectivity_test
                queue_utility(
                  tool: "queue_inventory_connectivity_test",
                  scope: "control_center_ansible_inventory_connectivity_test",
                  allowed: %w[credential_id]
                ) do |inventory, body|
                  credential = body["credential_id"] &&
                    ::ControlCenter::Ansible::Credential.find_by(id: body["credential_id"])
                  raise ActiveRecord::RecordNotFound if body["credential_id"] && !credential
                  ::ControlCenter::Ansible::ExecutorTaskBuilder.connectivity_test(
                    user: machine_user, inventory: inventory, credential: credential
                  )
                end
              end

              def confirm_host_keys
                tool = "confirm_inventory_host_keys"
                reservation = authorize_tool!(
                  tool, scope: "control_center_ansible_inventory_host_keys_confirm"
                )
                body = exact_machine_body(reservation, %w[expected_lock_version candidates])
                return unless body
                expected = body["expected_lock_version"]
                inventory = find_inventory
                return machine_not_found(reservation) unless inventory
                unless expected.is_a?(Integer) && expected == inventory.lock_version &&
                    valid_candidates?(body["candidates"])
                  reservation.fail!
                  return render json: { error: "version_conflict" }, status: :conflict
                end
                idempotency_key = machine_idempotency_key(tool,
                  { id: inventory.id, expected_lock_version: expected, candidates: body["candidates"] })
                return if replay_machine_action(reservation, tool: tool, idempotency_key: idempotency_key)
                return unless consume_machine_effect!(reservation)
                inventory = inventory.with_lock do
                  raise ActiveRecord::StaleObjectError unless inventory.lock_version == expected
                  ::ControlCenter::Ansible::HostKeyConfirmation.call(
                    inventory: inventory, candidates: body["candidates"]
                  )
                end
                receipt = issue_machine_receipt(
                  tool: tool, status: "updated", target_type: "ansible_inventory",
                  target_id: inventory.id, idempotency_key: idempotency_key
                )
                complete_machine_effect!(reservation, receipt: receipt)
              rescue ActiveRecord::StaleObjectError
                reservation.fail!
                render json: { error: "version_conflict" }, status: :conflict
              rescue ::ControlCenter::Ansible::HostKeyConfirmation::Error
                render_machine_validation_error(reservation, [ "ansible_host_key_confirmation_invalid" ])
              end

              def utility_task
                reservation = authorize_tool!(
                  "get_inventory_utility_task", scope: "control_center_ansible_inventories_read"
                )
                task = ::ControlCenter::Ansible::ExecutorTask.find_by(
                  id: params[:task_id], inventory_id: params[:id]
                )
                return machine_not_found(reservation) unless task
                detail_response(reservation, key: :utility_task, value: PROJECTION.utility_task(task))
              end

              private

              def find_inventory
                ::ControlCenter::Ansible::Inventory.includes(:variable_sets).find_by(id: params[:id])
              end

              def resolve_resources(input)
                credential_id = input.attributes["default_credential_id"]
                credential = credential_id && ::ControlCenter::Ansible::Credential.find_by(id: credential_id)
                return if credential_id && !credential
                ids = input.variable_set_ids
                sets = ids && ::ControlCenter::Ansible::VariableSet.where(id: ids).index_by(&:id)
                return if ids && sets.length != ids.length
                { credential: credential, variable_sets: ids && ids.map { |id| sets.fetch(id) } }
              end

              def persist_inventory(inventory, input, resources)
                ::ControlCenter::Ansible::Inventory.transaction do
                  inventory.assign_attributes(input.attributes)
                  inventory.default_credential = resources.fetch(:credential) if
                    input.attributes.key?("default_credential_id")
                  inventory.save!
                  if input.variable_set_ids
                    inventory.inventory_variable_sets.destroy_all
                    resources.fetch(:variable_sets).each_with_index do |set, index|
                      inventory.inventory_variable_sets.create!(variable_set: set, position: index)
                    end
                  end
                  inventory.reload
                end
              rescue ActiveRecord::RecordInvalid, ActiveRecord::StaleObjectError
                nil
              end

              def queue_utility(tool:, scope:, allowed:)
                reservation = authorize_tool!(tool, scope: scope)
                body = exact_machine_body(reservation, allowed)
                return unless body
                inventory = find_inventory
                return machine_not_found(reservation) unless inventory
                idempotency_key = machine_idempotency_key(tool, { id: inventory.id, input: body })
                return if replay_machine_action(reservation, tool: tool, idempotency_key: idempotency_key)
                return unless consume_machine_effect!(reservation, launch: true)
                task = yield(inventory, body)
                receipt = issue_machine_receipt(
                  tool: tool, status: "queued", target_type: "ansible_utility_task",
                  target_id: task.id, idempotency_key: idempotency_key
                )
                complete_machine_effect!(reservation, receipt: receipt, status: :accepted)
              rescue ActiveRecord::RecordNotFound
                reservation.fail!
                render json: { error: "not_found" }, status: :not_found
              rescue ::ControlCenter::Ansible::ExecutorTaskBuilder::Error
                render_machine_validation_error(reservation, [ "ansible_utility_task_invalid" ])
              end

              def valid_candidates?(value)
                value.is_a?(Array) && value.any? && value.length <= 1_000 && value.all? do |raw|
                  candidate = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
                  candidate.is_a?(Hash) && candidate.stringify_keys.keys.sort ==
                    %w[expected_fingerprint host known_hosts_line port scanned_fingerprint].sort &&
                    Assistant::Context::SecretDetector.safe?(candidate)
                end
              end
            end
          end
        end
      end
    end
  end
end
