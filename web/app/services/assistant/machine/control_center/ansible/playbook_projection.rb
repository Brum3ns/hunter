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
              "name" => playbook.name,
              "description" => playbook.description,
              "checksum" => playbook.checksum,
              "updated_at" => playbook.updated_at
            }
          end

          def full(playbook)
            summary(playbook).merge(
              "yaml_content" => playbook.yaml_content,
              "variable_set_ids" => playbook.variable_set_ids,
              "created_at" => playbook.created_at
            )
          end
        end
      end
    end
  end
end
