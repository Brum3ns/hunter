module Assistant
  module Machine
    module ControlCenter
      module Ansible
        module VariableInput
          Result = Data.define(:valid, :attributes, :codes) do
            def valid? = valid
          end

          FIELDS = %w[name value_type value position].freeze
          NAME_PATTERN = /\A[A-Za-z_][A-Za-z0-9_]*\z/
          SECRET_NAME_PATTERN = /(?:\A|_)(?:api|access|refresh|auth|session|private)?_?(?:key|token|secret|password|passwd)(?:\z|_)/i

          module_function

          def call(value, existing: nil)
            raw = value.respond_to?(:to_unsafe_h) ? value.to_unsafe_h : value
            return failure("ansible_variable_invalid") unless raw.is_a?(Hash)

            input = raw.deep_stringify_keys
            return failure("assistant_unknown_input") if (input.keys - FIELDS).any?
            return failure("ansible_variable_changes_empty") if existing && input.empty?
            return failure("ansible_secret_variable_denied") if existing&.secret?

            name = input.key?("name") ? input["name"] : existing&.name
            type = input.key?("value_type") ? input["value_type"] : existing&.value_type
            value_supplied = input.key?("value")
            typed_value = value_supplied ? input["value"] : existing&.typed_value
            position = input.key?("position") ? input["position"] : (existing&.position || 0)

            return failure("ansible_variable_name_invalid") unless valid_name?(name)
            return failure("ansible_variable_type_invalid") unless
              ::ControlCenter::Ansible::Variable::VALUE_TYPES.include?(type)
            return failure("ansible_variable_value_required") unless existing || value_supplied
            return failure("ansible_variable_position_invalid") unless
              position.is_a?(Integer) && position.between?(0, 1_000_000)
            return failure("assistant_secret_input_denied") unless
              Assistant::Context::SecretDetector.safe?({ "variable" => { name => typed_value } })

            serialized = ::ControlCenter::Ansible::TypedValue.dump(typed_value, type: type)
            attributes = {
              name: name, value_type: type, serialized_value: serialized,
              position: position, secret: false
            }
            Result.new(valid: true, attributes: attributes.freeze, codes: [])
          rescue ::ControlCenter::Ansible::TypedValue::Error
            failure("ansible_variable_value_invalid")
          rescue NoMethodError
            failure("ansible_variable_invalid")
          end

          def valid_name?(name)
            name.is_a?(String) && name.bytesize <= 255 && name.match?(NAME_PATTERN) &&
              !name.match?(Assistant::Context::SecretDetector::CREDENTIAL_KEY) &&
              !name.match?(SECRET_NAME_PATTERN) &&
              !::ControlCenter::Ansible::YamlLimits::VARIABLE_RESERVED_CONNECTION_KEYS.include?(name.downcase)
          end
          private_class_method :valid_name?

          def failure(code)
            Result.new(valid: false, attributes: nil, codes: [ code ])
          end
          private_class_method :failure
        end
      end
    end
  end
end
