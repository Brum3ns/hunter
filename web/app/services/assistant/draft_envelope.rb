module Assistant
  module DraftEnvelope
    MAX_NAME_LENGTH = 200
    MAX_DESCRIPTION_LENGTH = 4_000
    MAX_COMMAND_LENGTH = 255
    WHITERABBIT_FIELDS = %w[name kind description commands].freeze
    COMMAND_FIELDS = %w[command args operator].freeze
    ANSIBLE_FIELDS = %w[name source].freeze

    ParseResult = Data.define(:normalized, :codes, :messages) do
      def valid?
        codes.empty?
      end
    end

    module_function

    def whiterabbit(value)
      attributes = closed_hash(value)
      return invalid("whiterabbit_draft_invalid", "Draft must be an object.") unless attributes

      codes = []
      messages = []
      add_issue(codes, messages, "whiterabbit_draft_unknown_field", "Draft contains an unsupported field.") if
        (attributes.keys - WHITERABBIT_FIELDS).any?

      name = required_string(attributes["name"], max: MAX_NAME_LENGTH,
        code: "whiterabbit_name_invalid", label: "Draft name", codes: codes, messages: messages)
      kind = required_string(attributes["kind"], max: 40,
        code: "whiterabbit_kind_invalid", label: "Draft kind", codes: codes, messages: messages)
      if kind && !ControlCenter::Template::KINDS.include?(kind)
        add_issue(codes, messages, "whiterabbit_kind_not_allowed", "Draft kind is not permitted.")
      end
      description = if attributes.key?("description")
        optional_string(attributes["description"], max: MAX_DESCRIPTION_LENGTH,
          code: "whiterabbit_description_invalid", label: "Draft description", codes: codes, messages: messages)
      else
        ""
      end
      commands = normalize_commands(attributes["commands"], codes, messages)

      normalized = if codes.empty?
        {
          "name" => name,
          "kind" => kind,
          "description" => description,
          "commands" => commands
        }
      end
      ParseResult.new(normalized: normalized, codes: codes.freeze, messages: messages.freeze)
    end

    def ansible(value)
      attributes = closed_hash(value)
      return invalid("ansible_draft_invalid", "Draft must be an object.") unless attributes

      codes = []
      messages = []
      add_issue(codes, messages, "ansible_draft_unknown_field", "Draft contains an unsupported field.") if
        (attributes.keys - ANSIBLE_FIELDS).any?
      name = required_string(attributes["name"], max: MAX_NAME_LENGTH,
        code: "ansible_name_invalid", label: "Draft name", codes: codes, messages: messages)
      source = attributes["source"]
      unless source.is_a?(String) && source.present? && source.valid_encoding? &&
          !source.include?("\x00") && source.bytesize <= Assistant::DraftValidation::AnsibleStatic::MAX_SOURCE_BYTES
        add_issue(codes, messages, "ansible_source_invalid", "Ansible source is invalid.")
        source = nil
      end

      normalized = { "name" => name, "source" => source } if codes.empty?
      ParseResult.new(normalized: normalized, codes: codes.freeze, messages: messages.freeze)
    end

    def normalize_commands(value, codes, messages)
      unless value.is_a?(Array) && value.any?
        add_issue(codes, messages, "whiterabbit_commands_invalid", "At least one command is required.")
        return []
      end
      if value.length > ControlCenter::TemplateValidator::MAX_COMMANDS
        add_issue(codes, messages, "whiterabbit_too_many_commands", "Draft has too many commands.")
      end

      value.first(ControlCenter::TemplateValidator::MAX_COMMANDS).each_with_index.map do |raw, index|
        command = closed_hash(raw)
        unless command
          add_issue(codes, messages, "whiterabbit_command_invalid", "Command #{index + 1} must be an object.")
          next
        end
        add_issue(codes, messages, "whiterabbit_command_unknown_field", "Command #{index + 1} contains an unsupported field.") if
          (command.keys - COMMAND_FIELDS).any?

        name = required_string(command["command"], max: MAX_COMMAND_LENGTH,
          code: "whiterabbit_command_invalid", label: "Command #{index + 1} name", codes: codes, messages: messages)
        args = normalize_args(command["args"], index, codes, messages)
        operator = command["operator"]
        unless operator.is_a?(String) && ControlCenter::TemplateValidator::ALLOWED_OPERATORS.include?(operator)
          add_issue(codes, messages, "whiterabbit_operator_invalid", "Command #{index + 1} operator is invalid.")
          operator = nil
        end

        { "command" => name, "args" => args, "operator" => operator }
      end.compact
    end
    private_class_method :normalize_commands

    def normalize_args(value, command_index, codes, messages)
      unless value.is_a?(Array)
        add_issue(codes, messages, "whiterabbit_args_invalid", "Command #{command_index + 1} arguments must be an array.")
        return []
      end
      if value.length > ControlCenter::TemplateValidator::MAX_ARGS
        add_issue(codes, messages, "whiterabbit_too_many_args", "Command #{command_index + 1} has too many arguments.")
      end

      value.first(ControlCenter::TemplateValidator::MAX_ARGS).each_with_index.filter_map do |argument, argument_index|
        unless argument.is_a?(String) && safe_string?(argument) && argument.length <= ControlCenter::TemplateValidator::MAX_ARG_LENGTH
          add_issue(codes, messages, "whiterabbit_arg_invalid",
            "Command #{command_index + 1} argument #{argument_index + 1} is invalid.")
          next
        end
        argument
      end
    end
    private_class_method :normalize_args

    def required_string(value, max:, code:, label:, codes:, messages:)
      unless value.is_a?(String) && value.present? && value.length <= max && safe_string?(value)
        add_issue(codes, messages, code, "#{label} is invalid.")
        return
      end
      value
    end
    private_class_method :required_string

    def optional_string(value, max:, code:, label:, codes:, messages:)
      unless value.is_a?(String) && value.length <= max && safe_string?(value)
        add_issue(codes, messages, code, "#{label} is invalid.")
        return
      end
      value
    end
    private_class_method :optional_string

    def safe_string?(value)
      value.valid_encoding? && !value.match?(ControlCenter::TemplateValidator::FORBIDDEN_CHARS) &&
        !value.include?("\u2028") && !value.include?("\u2029")
    end
    private_class_method :safe_string?

    def closed_hash(value)
      raw = value.respond_to?(:to_unsafe_h) ? value.to_unsafe_h : value
      return unless raw.is_a?(Hash)

      raw.deep_stringify_keys
    end
    private_class_method :closed_hash

    def add_issue(codes, messages, code, message)
      codes << code
      messages << message
    end
    private_class_method :add_issue

    def invalid(code, message)
      ParseResult.new(normalized: nil, codes: [ code ].freeze, messages: [ message ].freeze)
    end
    private_class_method :invalid
  end
end
