module Assistant
  module Machine
    module ControlCenter
      # Bounded, redaction-safe field allowlist the Assistant may read from a
      # ControlCenter::Job. Never returns the raw ActiveRecord attributes:
      # template_snapshot, selections, manual_targets, and idempotency_key are
      # targeting/internal fields and are never projected, even in `full`. The
      # key sets here are a contract with the MCP cc_jobs module's closed
      # output validators (assistant/mcp/internal/modules/cc_jobs/module.go)
      # — change both together.
      module JobProjection
        module_function

        def summary(job)
          {
            "id" => job.id,
            "template_name" => job.template_name,
            "status" => job.status,
            "queue_name" => job.queue_name,
            "target_count" => job.target_count,
            "exit_status" => job.exit_status,
            "created_at" => job.created_at
          }
        end

        def full(job)
          summary(job).merge(
            "stdout" => job.stdout,
            "stderr" => job.stderr,
            "updated_at" => job.updated_at
          )
        end
      end
    end
  end
end
