module Assistant
  module Machine
    module ControlCenter
      module Ansible
        # Bounded, redaction-safe field allowlist the Assistant may read from a
        # ControlCenter::Ansible::Playbook. The key sets here are a contract
        # with the MCP cc_playbooks module's closed output validators
        # (assistant/mcp/internal/modules/cc_playbooks/module.go) — change
        # both together.
        module PlaybookProjection
          module_function

          def summary(playbook)
            {
              "id" => playbook.id,
              "name" => safe_text(playbook.name),
              "description" => safe_text(playbook.description),
              "checksum" => playbook.checksum,
        "lock_version" => playbook.lock_version,
        "created_by" => safe_text(playbook.created_by.username),
              "updated_at" => playbook.updated_at
            }
          end

          def full(playbook)
            summary(playbook).merge(
              "yaml_content" => safe_text(playbook.yaml_content),
              "variable_set_ids" => playbook.variable_set_ids,
              "created_at" => playbook.created_at
            )
          end

          def safe_text(value)
            return nil if value.nil?

            ::Assistant::Machine::SensitiveData.text(value.to_s, max_bytes: 65_536).value
          end
          private_class_method :safe_text
        end
      end
    end
  end
end
