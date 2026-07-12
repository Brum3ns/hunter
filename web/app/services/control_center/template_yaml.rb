require "yaml"

module ControlCenter
  # Safe parser: raw cmdscript YAML -> normalized Template attributes. The YAML
  # security core. Never YAML.load/unsafe_load — safe_load with no permitted
  # classes and aliases disabled blocks object-injection and alias/anchor bombs.
  # Returns [attrs_hash, []] on success or [nil, [error_strings]]. Does NOT run
  # the command allowlist — that stays in TemplateValidator, called by the model.
  module TemplateYaml
    module_function

    MAX_YAML_BYTES = 64_000
    ALLOWED_KEYS = %w[name kind tags desc description output commands target].freeze
    KINDS = %w[cmdscript workflow].freeze
    COMMAND_KEYS = %w[command args operator].freeze
    TARGET_KEYS = %w[type separator output].freeze

    def parse(str)
      str = str.to_s
      return [nil, ["YAML is empty"]] if str.strip.empty?
      return [nil, ["YAML is too large (max #{MAX_YAML_BYTES} bytes)"]] if str.bytesize > MAX_YAML_BYTES

      begin
        doc = YAML.safe_load(str, permitted_classes: [], permitted_symbols: [], aliases: false)
      rescue Psych::SyntaxError => e
        return [nil, ["YAML syntax error: #{e.message}"]]
      rescue StandardError => e
        return [nil, ["disallowed or invalid YAML: #{e.class}"]]
      end

      return [nil, ["template must be a YAML mapping"]] unless doc.is_a?(Hash)

      errors = []
      d = doc.transform_keys(&:to_s)
      unknown = d.keys - ALLOWED_KEYS
      errors << "unknown key(s): #{unknown.join(', ')}" if unknown.any?

      attrs = {
        "name" => required_string(d, "name", errors),
        "kind" => kind_field(d, errors),
        "tags" => string_list(d, "tags", errors),
        "description" => description_field(d, errors),
        "output" => optional_string(d, "output", errors),
        "commands" => commands_field(d, errors),
        "target" => target_field(d, errors)
      }
      attrs.reject! { |_k, v| v.nil? }

      return [nil, errors] if errors.any?
      [attrs, []]
    end

    def required_string(d, key, errors)
      unless d.key?(key)
        errors << "#{key} is required"
        return nil
      end
      return d[key] if d[key].is_a?(String)
      errors << "#{key} must be a string"
      nil
    end

    def optional_string(d, key, errors)
      return nil unless d.key?(key)
      return d[key] if d[key].is_a?(String)
      errors << "#{key} must be a string"
      nil
    end

    def kind_field(d, errors)
      return "cmdscript" unless d.key?("kind")
      v = d["kind"]
      return v if v.is_a?(String) && KINDS.include?(v)
      errors << "kind must be one of #{KINDS.join('/')}"
      "cmdscript"
    end

    def description_field(d, errors)
      key = d.key?("desc") ? "desc" : "description"
      return "" unless d.key?(key)
      return d[key] if d[key].is_a?(String)
      errors << "#{key} must be a string"
      ""
    end

    def string_list(d, key, errors)
      return [] unless d.key?(key)
      v = d[key]
      return v if v.is_a?(Array) && v.all? { |x| x.is_a?(String) }
      errors << "#{key} must be a list of strings"
      []
    end

    def commands_field(d, errors)
      v = d["commands"]
      unless v.is_a?(Array)
        errors << "commands must be a list"
        return []
      end
      v.each_with_index.map { |raw, i| command_entry(raw, i, errors) }
    end

    def command_entry(raw, i, errors)
      unless raw.is_a?(Hash)
        errors << "commands[#{i}] must be a mapping"
        return {}
      end
      c = raw.transform_keys(&:to_s)
      bad = c.keys - COMMAND_KEYS
      errors << "commands[#{i}] has unknown key(s): #{bad.join(', ')}" if bad.any?

      name = c["command"]
      unless name.is_a?(String)
        errors << "commands[#{i}].command must be a string"
        name = ""
      end
      args = c.fetch("args", [])
      unless args.is_a?(Array)
        errors << "commands[#{i}].args must be a list"
        args = []
      end
      operator = c.fetch("operator", "")
      unless operator.is_a?(String)
        errors << "commands[#{i}].operator must be a string"
        operator = ""
      end
      { "command" => name, "args" => args.map(&:to_s), "operator" => operator }
    end

    def target_field(d, errors)
      return nil unless d.key?("target")
      v = d["target"]
      unless v.is_a?(Hash)
        errors << "target must be a mapping"
        return nil
      end
      t = v.transform_keys(&:to_s)
      bad = t.keys - TARGET_KEYS
      errors << "target has unknown key(s): #{bad.join(', ')}" if bad.any?
      TARGET_KEYS.each do |k|
        errors << "target.#{k} must be a string" if t.key?(k) && !t[k].is_a?(String)
      end
      t.slice(*TARGET_KEYS)
    end
  end
end
