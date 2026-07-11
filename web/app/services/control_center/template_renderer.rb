module ControlCenter
  # Template row -> Whiterabbit cmdscript YAML. Field names match
  # pkg/cmdscript/cmdscript.go: name, tags, desc, output, commands[command/args/operator], target.
  module TemplateRenderer
    module_function

    def to_yaml(template)
      to_hash(template).to_yaml
    end

    def to_hash(template)
      hash = {
        "name" => template.name.to_s,
        "tags" => Array(template.tags),
        "desc" => template.description.to_s,
        "commands" => Array(template.commands).map { |c| command_hash(c) }
      }
      hash["output"] = template.output if template.output.present?
      hash["target"] = template.target if template.target.present?
      hash
    end

    def command_hash(raw)
      c = (raw || {}).to_h.transform_keys(&:to_s)
      h = { "command" => c["command"].to_s, "args" => Array(c["args"]) }
      h["operator"] = c["operator"] if c["operator"].present?
      h
    end
  end
end
