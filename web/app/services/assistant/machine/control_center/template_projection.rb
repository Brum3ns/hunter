module Assistant
  module Machine
    module ControlCenter
      # Bounded, redaction-safe field allowlist the Assistant may read from a
      # ControlCenter::Template. Never returns the raw ActiveRecord attributes
      # and includes non-secret authoring metadata. The key sets here are a contract
      # with the MCP cc_templates module's closed output validators
      # (assistant/mcp/internal/modules/cc_templates/module.go) — change both
      # together.
      module TemplateProjection
        module_function

        def summary(template)
          {
            "id" => template.id,
            "name" => safe_text(template.name),
            "kind" => safe_text(template.kind),
            "description" => safe_text(template.description),
            "tags" => Array(template.tags).first(50).map { |tag| safe_text(tag) },
			"lock_version" => template.lock_version,
			"created_by" => safe_text(template.created_by),
            "updated_at" => template.updated_at
          }
        end

        def full(template)
          summary(template).merge(
            "output" => safe_text(template.output),
            "commands" => commands(template.commands),
            "target" => target(template.target),
            "created_at" => template.created_at
          )
        end

        def commands(value)
          Array(value).first(::ControlCenter::TemplateValidator::MAX_COMMANDS).map do |raw|
            command = raw.is_a?(Hash) ? raw : {}
            {
              "command" => safe_text(command["command"]),
              "args" => Array(command["args"]).first(::ControlCenter::TemplateValidator::MAX_ARGS)
                .map { |argument| safe_text(argument) },
              "operator" => safe_text(command["operator"] || "")
            }
          end
        end
        private_class_method :commands

        def target(value)
          return nil unless value.is_a?(Hash)

          {
            "type" => safe_text(value["type"]),
            "separator" => safe_text(value["separator"]),
            "output" => safe_text(value["output"])
          }
        end
        private_class_method :target

        def safe_text(value)
          return nil if value.nil?

          ::Assistant::Machine::SensitiveData.text(value.to_s).value
        end
        private_class_method :safe_text
      end
    end
  end
end
