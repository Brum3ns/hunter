module Assistant
  module Machine
    module ControlCenter
      module Ansible
        # Bounded, redaction-safe field allowlist the Assistant may read from a
        # ControlCenter::Ansible::Run. Never returns `playbook_yaml`,
        # `inventory_yaml`, `known_hosts`, `lease_digest`, or `runner_id` —
        # `variable_audit`/`secret_variable_names` are safe by construction
        # (audit values omit secret values; the names list carries names
        # only). The key sets here are a contract with the MCP cc_runs
        # module's closed output validators
        # (assistant/mcp/internal/modules/cc_runs/module.go) — change both
        # together.
        module RunProjection
          module_function

          # Used both standalone (get_run) and nested under a run group's
          # `runs` array.
          def summary(run)
            {
              "id" => run.id,
              "position" => run.position,
              "status" => run.status,
              "playbook_name" => run.playbook_name,
              "exit_status" => run.exit_status
            }
          end

          def full(run)
            {
              "id" => run.id,
              "run_group_id" => run.run_group_id,
              "playbook_id" => run.playbook_id,
              "position" => run.position,
              "status" => run.status,
              "playbook_name" => run.playbook_name,
              "inventory_name" => run.inventory_name,
              "credential_name" => run.credential_name,
              "credential_fingerprint" => run.credential_fingerprint,
              "variable_audit" => run.variable_audit,
              "secret_variable_names" => run.secret_variable_names,
              "host_limit" => run.host_limit,
              "check_mode" => run.check_mode,
              "timeout_seconds" => run.timeout_seconds,
              "error_code" => run.error_code,
              "error_detail" => run.error_detail,
              "exit_status" => run.exit_status,
              "ok_count" => run.ok_count,
              "changed_count" => run.changed_count,
              "failed_count" => run.failed_count,
              "unreachable_count" => run.unreachable_count,
              "stored_event_bytes" => run.stored_event_bytes,
              "truncated" => run.truncated,
              "queued_at" => run.queued_at,
              "started_at" => run.started_at,
              "completed_at" => run.completed_at,
              "cancel_requested_at" => run.cancel_requested_at,
              "created_at" => run.created_at,
              "updated_at" => run.updated_at
            }
          end
        end
      end
    end
  end
end
