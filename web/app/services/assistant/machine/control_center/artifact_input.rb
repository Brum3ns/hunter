module Assistant
  module Machine
    module ControlCenter
      module ArtifactInput
        WHITERABBIT_FIELDS = %w[name kind tags description output commands target].freeze
        COMMAND_FIELDS = %w[command args operator].freeze
        TARGET_FIELDS = %w[type separator output].freeze
        ANSIBLE_FIELDS = %w[name description source variable_set_ids].freeze
        MAX_TAGS = 50
        MAX_TAG_LENGTH = 200
        MAX_OUTPUT_LENGTH = 4_000
        MAX_VARIABLE_SETS = 100

        Result = Data.define(:normalized, :codes) do
          def valid?
            codes.empty?
          end
        end

        module_function

        def whiterabbit_create(value)
          normalize_whiterabbit(value, partial: false)
        end

        def whiterabbit_changes(value)
          normalize_whiterabbit(value, partial: true)
        end

        def ansible_create(value)
          normalize_ansible(value, partial: false)
        end

        def ansible_changes(value)
          normalize_ansible(value, partial: true)
        end

        def normalize_whiterabbit(value, partial:)
          attributes = closed_hash(value)
          return invalid("whiterabbit_draft_invalid") unless attributes

          codes = []
          codes << "whiterabbit_draft_unknown_field" if (attributes.keys - WHITERABBIT_FIELDS).any?
          codes << "whiterabbit_changes_empty" if partial && attributes.empty?
          normalized = {}

          normalize_string_field(attributes, normalized, "name", codes,
            required: !partial, allow_empty: false, max: Assistant::DraftEnvelope::MAX_NAME_LENGTH,
            code: "whiterabbit_name_invalid")
          if attributes.key?("kind")
            kind = attributes["kind"]
            if kind.is_a?(String) && ::ControlCenter::Template::KINDS.include?(kind)
              normalized["kind"] = kind
            else
              codes << "whiterabbit_kind_not_allowed"
            end
          elsif !partial
            codes << "whiterabbit_kind_invalid"
          end
          if attributes.key?("description")
            normalize_string_field(attributes, normalized, "description", codes,
              required: false, allow_empty: true, max: Assistant::DraftEnvelope::MAX_DESCRIPTION_LENGTH,
              code: "whiterabbit_description_invalid")
          elsif !partial
            normalized["description"] = ""
          end
          normalize_string_field(attributes, normalized, "output", codes,
            required: false, allow_empty: true, max: MAX_OUTPUT_LENGTH,
            code: "whiterabbit_output_invalid") if attributes.key?("output")
          normalize_tags(attributes["tags"], normalized, codes) if attributes.key?("tags")
          if attributes.key?("commands")
            normalized["commands"] = normalize_commands(attributes["commands"], codes)
          elsif !partial
            codes << "whiterabbit_commands_invalid"
          end
          normalize_target(attributes["target"], normalized, codes) if attributes.key?("target")

          finish(normalized, codes)
        end
        private_class_method :normalize_whiterabbit

        def normalize_ansible(value, partial:)
          attributes = closed_hash(value)
          return invalid("ansible_draft_invalid") unless attributes

          codes = []
          codes << "ansible_draft_unknown_field" if (attributes.keys - ANSIBLE_FIELDS).any?
          codes << "ansible_changes_empty" if partial && attributes.empty?
          normalized = {}
          normalize_string_field(attributes, normalized, "name", codes,
            required: !partial, allow_empty: false, max: Assistant::DraftEnvelope::MAX_NAME_LENGTH,
            code: "ansible_name_invalid")
          normalize_string_field(attributes, normalized, "description", codes,
            required: false, allow_empty: true, max: Assistant::DraftEnvelope::MAX_DESCRIPTION_LENGTH,
            code: "ansible_description_invalid") if attributes.key?("description")

          if attributes.key?("source")
            source = attributes["source"]
            if source.is_a?(String) && source.present? && source.valid_encoding? &&
                !source.include?("\x00") && source.bytesize <= Assistant::DraftValidation::AnsibleStatic::MAX_SOURCE_BYTES
              normalized["source"] = source.dup
            else
              codes << "ansible_source_invalid"
            end
          elsif !partial
            codes << "ansible_source_invalid"
          end
          normalize_variable_set_ids(attributes["variable_set_ids"], normalized, codes) if
            attributes.key?("variable_set_ids")

          finish(normalized, codes)
        end
        private_class_method :normalize_ansible

        def normalize_string_field(attributes, normalized, key, codes, required:, allow_empty:, max:, code:)
          unless attributes.key?(key)
            codes << code if required
            return
          end
          value = attributes[key]
          valid = value.is_a?(String) && value.valid_encoding? && value.length <= max &&
            (allow_empty || value.present?) && !value.match?(::ControlCenter::TemplateValidator::FORBIDDEN_CHARS) &&
            !value.include?("\u2028") && !value.include?("\u2029")
          if valid
            normalized[key] = value.dup
          else
            codes << code
          end
        end
        private_class_method :normalize_string_field

        def normalize_tags(value, normalized, codes)
          valid = value.is_a?(Array) && value.length <= MAX_TAGS && value.all? do |tag|
            tag.is_a?(String) && tag.valid_encoding? && tag.length <= MAX_TAG_LENGTH &&
              !tag.match?(::ControlCenter::TemplateValidator::FORBIDDEN_CHARS)
          end
          valid ? normalized["tags"] = value.map(&:dup) : codes << "whiterabbit_tags_invalid"
        end
        private_class_method :normalize_tags

        def normalize_commands(value, codes)
          unless value.is_a?(Array) && value.any? && value.length <= ::ControlCenter::TemplateValidator::MAX_COMMANDS
            codes << "whiterabbit_commands_invalid"
            return []
          end

          value.map.with_index do |raw, index|
            command = closed_hash(raw)
            unless command
              codes << "whiterabbit_command_invalid"
              next {}
            end
            codes << "whiterabbit_command_unknown_field" if (command.keys - COMMAND_FIELDS).any?
            name = command["command"]
            unless name.is_a?(String) && name.present? && name.valid_encoding? &&
                name.length <= Assistant::DraftEnvelope::MAX_COMMAND_LENGTH &&
                !name.match?(::ControlCenter::TemplateValidator::FORBIDDEN_CHARS)
              codes << "whiterabbit_command_invalid"
              name = ""
            end
            args = command.key?("args") ? command["args"] : []
            unless args.is_a?(Array) && args.length <= ::ControlCenter::TemplateValidator::MAX_ARGS &&
                args.all? { |arg| valid_argument?(arg) }
              codes << "whiterabbit_args_invalid"
              args = []
            end
            operator = command.key?("operator") ? command["operator"] : ""
            unless operator.is_a?(String) && ::ControlCenter::TemplateValidator::ALLOWED_OPERATORS.include?(operator)
              codes << "whiterabbit_operator_invalid"
              operator = ""
            end
            { "command" => name.dup, "args" => args.map(&:dup), "operator" => operator.dup }
          end
        end
        private_class_method :normalize_commands

        def valid_argument?(argument)
          argument.is_a?(String) && argument.valid_encoding? &&
            argument.length <= ::ControlCenter::TemplateValidator::MAX_ARG_LENGTH &&
            !argument.match?(::ControlCenter::TemplateValidator::FORBIDDEN_CHARS)
        end
        private_class_method :valid_argument?

        def normalize_target(value, normalized, codes)
          target = closed_hash(value)
          unless target
            codes << "whiterabbit_target_invalid"
            return
          end
          codes << "whiterabbit_target_unknown_field" if (target.keys - TARGET_FIELDS).any?
          normalized_target = {}
          { "type" => 100, "separator" => 20, "output" => MAX_OUTPUT_LENGTH }.each do |key, max|
            next unless target.key?(key)
            normalize_string_field(target, normalized_target, key, codes,
              required: false, allow_empty: true, max: max, code: "whiterabbit_target_invalid")
          end
          normalized["target"] = normalized_target
        end
        private_class_method :normalize_target

        def normalize_variable_set_ids(value, normalized, codes)
          valid = value.is_a?(Array) && value.length <= MAX_VARIABLE_SETS &&
            value.all? { |id| id.is_a?(Integer) && id.positive? } && value.uniq.length == value.length
          valid ? normalized["variable_set_ids"] = value.dup : codes << "ansible_variable_set_ids_invalid"
        end
        private_class_method :normalize_variable_set_ids

        def finish(normalized, codes)
          if codes.empty? && Assistant::Context::SecretDetector.detect(
              normalized, max_string_bytes: Assistant::DraftValidation::AnsibleStatic::MAX_SOURCE_BYTES
            )
            codes << "artifact_secret_material_not_allowed"
          end
          Result.new(normalized: codes.empty? ? normalized.freeze : nil, codes: codes.uniq.freeze)
        end
        private_class_method :finish

        def closed_hash(value)
          raw = value.respond_to?(:to_unsafe_h) ? value.to_unsafe_h : value
          raw.is_a?(Hash) ? raw.deep_stringify_keys : nil
        end
        private_class_method :closed_hash

        def invalid(code)
          Result.new(normalized: nil, codes: [ code ].freeze)
        end
        private_class_method :invalid
      end
    end
  end
end
