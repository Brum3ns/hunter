module Assistant
  module AuthoringPolicy
    PLACEHOLDERS = %w[__TARGET_FILE__ __TARGET_STDIN__ __UUID__].freeze

    module_function

    def for(artifact_type)
      case artifact_type.to_s
      when "whiterabbit_template"
        whiterabbit
      when "ansible_playbook"
        ansible
      end
    end

    def whiterabbit
      {
        schema_version: 1,
        validation_version: Assistant::DraftValidation::Whiterabbit::VALIDATION_VERSION,
        artifact_type: "whiterabbit_template",
        max_name_length: Assistant::DraftEnvelope::MAX_NAME_LENGTH,
        max_description_length: Assistant::DraftEnvelope::MAX_DESCRIPTION_LENGTH,
        max_commands: ControlCenter::TemplateValidator::MAX_COMMANDS,
        max_command_length: Assistant::DraftEnvelope::MAX_COMMAND_LENGTH,
        max_args: ControlCenter::TemplateValidator::MAX_ARGS,
        max_arg_length: ControlCenter::TemplateValidator::MAX_ARG_LENGTH,
        kinds: ControlCenter::Template::KINDS,
        operators: ControlCenter::TemplateValidator::ALLOWED_OPERATORS,
        placeholders: PLACEHOLDERS,
        command_policy: "unrestricted",
        required_validation: [ "closed_schema", "secret_material", "template_validator" ]
      }
    end
    private_class_method :whiterabbit

    def ansible
      {
        schema_version: 1,
        validation_version: Assistant::ValidationDispatcher::VALIDATION_VERSION,
        artifact_type: "ansible_playbook",
        max_name_length: Assistant::DraftEnvelope::MAX_NAME_LENGTH,
        max_source_bytes: Assistant::DraftValidation::AnsibleStatic::MAX_SOURCE_BYTES,
        module_allowlist: Assistant::DraftValidation::AnsibleStatic.module_allowlist,
        prohibited_constructs: %w[
          shell command raw script roles collections include import lookup query vars_prompt
          local_connection local_delegation environment vault absolute_path url custom_plugin
        ],
        required_validation: [ "closed_schema", "static_policy", "isolated_syntax_check" ]
      }
    end
    private_class_method :ansible
  end
end
