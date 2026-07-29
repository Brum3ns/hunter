module Assistant
  module Machine
    module ControlCenter
      # Bounded, redaction-safe field allowlist the Assistant may read from a
      # ControlCenter::Template. Never returns the raw ActiveRecord attributes
      # (excludes created_by, a username). The key sets here are a contract
      # with the MCP cc_templates module's closed output validators
      # (assistant/mcp/internal/modules/cc_templates/module.go) — change both
      # together.
      module TemplateProjection
        module_function

        def summary(template)
          {
            "id" => template.id,
            "name" => template.name,
            "kind" => template.kind,
            "description" => template.description,
            "tags" => template.tags,
            "updated_at" => template.updated_at
          }
        end

        def full(template)
          summary(template).merge(
            "output" => template.output,
            "commands" => template.commands,
            "target" => template.target,
            "created_at" => template.created_at
          )
        end
      end
    end
  end
end
