module Assistant
  module Machine
    module ControlCenter
      module Ansible
        # Bounded, redaction-safe field allowlist the Assistant may read from
        # a ControlCenter::Ansible::RunEvent. stdout/event_data are already
        # SecretRedactor-scrubbed at ingest time, so they are safe to
        # include. The key set here is a contract with the MCP
        # cc_run_events module's closed output validator
        # (assistant/mcp/internal/modules/cc_run_events/module.go) — change
        # both together.
        module RunEventProjection
          module_function

          def summary(event)
            {
              "id" => event.id,
              "counter" => event.counter,
              "event_uuid" => event.event_uuid,
              "parent_uuid" => event.parent_uuid,
              "event_type" => event.event_type,
              "play" => event.play,
              "task" => event.task,
              "host" => event.host,
              "event_time" => event.event_time,
              "stdout" => event.stdout,
              "event_data" => event.event_data,
              "truncated" => event.truncated,
              "created_at" => event.created_at
            }
          end
        end
      end
    end
  end
end
