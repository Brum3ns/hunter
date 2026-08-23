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
                reservation = authorize_tool!("list_run_groups", scope: "control_center_ansible_runs_read")
                page = machine_page
                limit = machine_limit(MAX_LIMIT)
                scope = ::ControlCenter::Ansible::RunGroup.order(created_at: :desc)
                count = scope.count
                rows = scope.offset((page - 1) * limit).limit(limit)
                items = rows.map { |group| ::Assistant::Machine::ControlCenter::Ansible::RunGroupProjection.summary(group) }
                list_response(reservation, count: count, page: page, limit: limit, items: items)
              end

              def show
                reservation = authorize_tool!("get_run_group", scope: "control_center_ansible_runs_read")
                group = ::ControlCenter::Ansible::RunGroup.includes(:runs).find_by(id: params[:id])
                return machine_not_found(reservation) unless group

                detail_response(
                  reservation, key: :run_group,
                  value: ::Assistant::Machine::ControlCenter::Ansible::RunGroupProjection.full(group)
                )
              end

              def analyze
                reservation = authorize_tool!("analyze_ansible_runs", scope: "control_center_ansible_runs_read")
                body = exact_machine_body(reservation, [])
                return unless body
                scope = ::ControlCenter::Ansible::RunGroup.order(created_at: :desc, id: :desc)
                count = scope.count
                groups = scope.limit(::Assistant::Machine::WorkflowAnalysis::MAX_ROWS).to_a
                complete_machine_response!(reservation, {
                  correlation_id: machine_grant.turn.correlation_id
                }.merge(::Assistant::Machine::WorkflowAnalysis.ansible_runs(groups, count: count)))
              end

              def create
                tool = "launch_ansible_run_group"
                reservation = authorize_tool!(tool, scope: "control_center_ansible_run_groups_launch")
                body = exact_machine_body(
                  reservation,
                  %w[playbook_id inventory_id credential_id variable_set_ids overrides host_limit check_mode timeout_seconds]
                )
                return unless body
                attributes = launch_attributes(body)
                return render_machine_validation_error(reservation, [ "ansible_launch_invalid" ]) unless attributes
                idempotency_key = machine_idempotency_key(tool, attributes)
                return if replay_machine_action(reservation, tool: tool, idempotency_key: idempotency_key)
                return unless consume_machine_effect!(reservation, launch: true)

                group = ::ControlCenter::Ansible::SingleLaunch.call(user: machine_user, **attributes)
                receipt = issue_machine_receipt(
                  tool: tool, status: "queued", target_type: "ansible_run_group",
                  target_id: group.id, idempotency_key: idempotency_key
                )
                complete_machine_effect!(reservation, receipt: receipt, status: :created)
              rescue ::ControlCenter::Ansible::SingleLaunch::Error
                render_machine_validation_error(reservation, [ "ansible_launch_invalid" ])
              end

              def cancel
                tool = "cancel_ansible_run_group"
                reservation = authorize_tool!(tool, scope: "control_center_ansible_run_groups_cancel")
                body = exact_machine_body(reservation, [])
                return unless body
                group = ::ControlCenter::Ansible::RunGroup.find_by(id: params[:id])
                return machine_not_found(reservation) unless group
                idempotency_key = machine_idempotency_key(tool, { id: group.id })
                return if replay_machine_action(reservation, tool: tool, idempotency_key: idempotency_key)
                return unless consume_machine_effect!(reservation, launch: true)
                ::ControlCenter::Ansible::RunCancellation.cancel_group!(group)
                receipt = issue_machine_receipt(
                  tool: tool, status: "cancelled", target_type: "ansible_run_group",
                  target_id: group.id, idempotency_key: idempotency_key
                )
                complete_machine_effect!(reservation, receipt: receipt)
              rescue ::ControlCenter::Ansible::RunCancellation::Conflict
                reservation.fail!
                render json: { error: "conflict" }, status: :conflict
              end

              private

              def launch_attributes(body)
                required_ids = %w[playbook_id inventory_id]
                return unless required_ids.all? { |key| body[key].is_a?(Integer) && body[key].positive? }
                credential_id = body["credential_id"]
                return unless credential_id.nil? || (credential_id.is_a?(Integer) && credential_id.positive?)
                set_ids = body.fetch("variable_set_ids", [])
                return unless set_ids.is_a?(Array) && set_ids.length <= 100 && set_ids.uniq.length == set_ids.length &&
                  set_ids.all? { |id| id.is_a?(Integer) && id.positive? }
                overrides = normalize_overrides(body.fetch("overrides", []))
                return unless overrides
                host_limit = body["host_limit"]
                check_mode = body.fetch("check_mode", false)
                timeout = body.fetch("timeout_seconds", 3_600)
                return unless (host_limit.nil? || (host_limit.is_a?(String) && host_limit.bytesize <= 255)) &&
                  [ true, false ].include?(check_mode) && timeout.is_a?(Integer) &&
                  timeout.between?(::ControlCenter::Ansible::SingleLaunch::MIN_TIMEOUT_SECONDS,
                    ::ControlCenter::Ansible::SingleLaunch::MAX_TIMEOUT_SECONDS)
                attributes = {
                  playbook_id: body["playbook_id"], inventory_id: body["inventory_id"],
                  credential_id: credential_id, variable_set_ids: set_ids, overrides: overrides,
                  host_limit: host_limit, check_mode: check_mode, timeout_seconds: timeout
                }
                attributes if ::Assistant::Context::SecretDetector.safe?(attributes)
              end

              def normalize_overrides(value)
                return unless value.is_a?(Array) && value.length <= 100
                value.map do |raw|
                  override = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
                  return unless override.is_a?(Hash)
                  override = override.deep_stringify_keys
                  return if (override.keys - %w[name value_type value]).any? ||
                    (override.keys & %w[name value_type value]).length != 3
                  return unless ::Assistant::Machine::ControlCenter::Ansible::VariableInput.send(
                    :valid_name?, override["name"]
                  )
                  return unless ::ControlCenter::Ansible::Variable::VALUE_TYPES.include?(override["value_type"])
                  ::ControlCenter::Ansible::TypedValue.dump(override["value"], type: override["value_type"])
                  override.symbolize_keys
                end
              rescue ::ControlCenter::Ansible::TypedValue::Error
                nil
              end
            end
          end
        end
      end
    end
  end
end
