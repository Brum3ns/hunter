module Assistant
  module Machine
    module ControlCenter
      module Ansible
        # Bounded, redaction-safe field allowlist the Assistant may read from a
        # ControlCenter::Ansible::RunGroup. Never returns `execution_payload`
        # (encrypted, resolved secrets) even in `full`. The key sets here are
        # a contract with the MCP cc_run_groups module's closed output
        # validators (assistant/mcp/internal/modules/cc_run_groups/module.go)
        # — change both together.
        module RunGroupProjection
          module_function

          def summary(group)
            {
              "id" => group.id,
              "status" => group.status,
              "execution_mode" => group.execution_mode,
              "failure_policy" => group.failure_policy,
              "inventory_id" => group.inventory_id,
              "credential_id" => group.credential_id,
              "started_at" => group.started_at,
              "completed_at" => group.completed_at,
              "created_at" => group.created_at
            }
          end

          def full(group)
            summary(group).merge(
              "concurrency_limit" => group.concurrency_limit,
              "launch_snapshot" => group.launch_snapshot,
              "cancel_requested_at" => group.cancel_requested_at,
              "updated_at" => group.updated_at,
              "runs" => Array(group.runs).map { |run| ::Assistant::Machine::ControlCenter::Ansible::RunProjection.summary(run) }
            )
          end
        end
      end
    end
  end
end
