require "yaml"

module ControlCenter
  # Template row -> Whiterabbit cmdscript YAML. Field names match
  # pkg/cmdscript/cmdscript.go: name, tags, desc, output, commands[command/args/operator], target.
  #
  # Args are stored flat ([String]) but rendered grouped: each flag (a token
  # starting with "-") and the values that follow it become one sub-array, e.g.
  # ["-u", "a", "-H", "h1", "h2"] -> [["-u", "a"], ["-H", "h1", "h2"]]. Whiterabbit's
  # makeArguments (pkg/cmdscript/utils.go) flattens either shape back to the same
  # argv "in correct order", so grouping is a readability convention that mirrors
  # how a command line reads. Groups render in flow style (['-u', 'a']); every
  # scalar is force single-quoted so a numeric- or boolean-looking value ('10',
  # 'y') stays a string (Whiterabbit asserts each sub-array element is a string).
  module TemplateRenderer
    module_function

    def to_yaml(template)
      dump(to_hash(template))
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
      h = { "command" => c["command"].to_s, "args" => group_args(Array(c["args"])) }
      h["operator"] = c["operator"] if c["operator"].present?
      h
    end

    # Flat argv -> list of flag groups. A flag opens a new group; following
    # non-flag tokens attach to it. A value-less flag or a token with no
    # preceding flag stays a bare string.
    def group_args(args)
      args.each_with_object([]) do |raw, result|
        s = raw.to_s
        if s.start_with?("-")
          result << s
        elsif result.any? && flag_group?(result.last)
          last = result.pop
          result << (last.is_a?(Array) ? last + [s] : [last, s])
        else
          result << s
        end
      end
    end

    def flag_group?(el)
      (el.is_a?(String) && el.start_with?("-")) || (el.is_a?(Array) && el.first.to_s.start_with?("-"))
    end

    # Dump to YAML, then render command `args` groups in flow style. Psych builds
    # and quotes the whole tree; we only flip the style of the arg sub-sequences.
    def dump(obj)
      visitor = Psych::Visitors::YAMLTree.create
      visitor << obj
      ast = visitor.tree
      flow_args!(ast)
      ast.yaml
    end

    def flow_args!(node)
      if node.is_a?(Psych::Nodes::Mapping)
        node.children.each_slice(2) do |key, value|
          if key.is_a?(Psych::Nodes::Scalar) && key.value == "args"
            flowify_args!(value)
          else
            flow_args!(value)
          end
        end
      elsif node.respond_to?(:children)
        node.children&.each { |child| flow_args!(child) }
      end
    end

    # The top-level args list always renders block, so a standalone token is a
    # plain string item (`- 'x'`) rather than a one-element flow array (`['x']`).
    # Only flag-group sub-sequences render flow (`['-u', 'x']`), so flow style
    # reads as "a flag with its values" and a block item as "a standalone token".
    # Every scalar leaf is then forced single-quoted so a numeric- or
    # boolean-looking value (10, y) stays a string — Psych's automatic quoting
    # leaves plain tokens (x, scan) bare, which Whiterabbit's per-element string
    # assert would reject.
    def flowify_args!(seq)
      return unless seq.is_a?(Psych::Nodes::Sequence) && seq.children.any?

      seq.children.each do |child|
        child.style = Psych::Nodes::Sequence::FLOW if child.is_a?(Psych::Nodes::Sequence) && child.children.any?
      end
      quote_scalars!(seq)
    end

    def quote_scalars!(node)
      if node.is_a?(Psych::Nodes::Scalar)
        node.plain = false
        node.quoted = true
        node.style = Psych::Nodes::Scalar::SINGLE_QUOTED
      elsif node.respond_to?(:children)
        node.children&.each { |child| quote_scalars!(child) }
      end
    end
  end
end
