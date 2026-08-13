module Assistant
  module Machine
    module ControlCenter
      # Bounded, redaction-safe field allowlist the Assistant may read from a
      # ControlCenter::Job. Never returns the raw ActiveRecord attributes:
      # template_snapshot, raw selections, raw manual targets, and
      # idempotency_key are internal fields and are never projected, even in
      # `full`. Safe counts/source names and execution parameters retain the
      # operational context needed to explain a prior job. The
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
          stdout = safe_text(job.stdout)
          stderr = safe_text(job.stderr)
          summary(job).merge(
            "created_by" => safe_text(job.created_by).value,
            "target_chunk" => job.target_chunk,
            "job_delay_ms" => job.job_delay_ms,
            "selection_count" => Array(job.selections).size,
            "manual_target_count" => Array(job.manual_targets).size,
            "selection_sources" => selection_sources(job.selections),
            "stdout" => stdout.value,
            "stdout_redacted" => stdout.redacted,
            "stderr" => stderr.value,
            "stderr_redacted" => stderr.redacted,
            "updated_at" => job.updated_at
          )
        end

        def safe_text(value)
          return ::Assistant::Machine::SensitiveData::Result.new(value: nil, redacted: false) if value.nil?

          ::Assistant::Machine::SensitiveData.text(value.to_s)
        end
        private_class_method :safe_text

        def selection_sources(selections)
          Array(selections).first(100).filter_map do |selection|
            next unless selection.is_a?(Hash)

            safe_text(selection["source"]).value
          end.uniq
        end
        private_class_method :selection_sources
      end
    end
  end
end
