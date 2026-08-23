module Assistant
  module Machine
    module ControlCenter
      module Ansible
        module InventoryInput
          Result = Data.define(:valid, :attributes, :variable_set_ids, :codes) do
            def valid? = valid
          end

          FIELDS = %w[name description yaml_content default_credential_id variable_set_ids].freeze

          module_function

          def call(value, partial:)
            raw = value.respond_to?(:to_unsafe_h) ? value.to_unsafe_h : value
            return failure("ansible_inventory_invalid") unless raw.is_a?(Hash)
            input = raw.deep_stringify_keys
            return failure("assistant_unknown_input") if (input.keys - FIELDS).any?
            return failure("ansible_inventory_changes_empty") if partial && input.empty?
            attributes = {}
            unless partial && !input.key?("name")
              name = input["name"]
              return failure("ansible_inventory_name_invalid") unless name.is_a?(String) && name.present? && name.bytesize <= 255
              attributes["name"] = name
            end
            if input.key?("description")
              description = input["description"]
              return failure("ansible_inventory_description_invalid") unless description.nil? ||
                (description.is_a?(String) && description.bytesize <= 4_000)
              attributes["description"] = description
            end
            unless partial && !input.key?("yaml_content")
              yaml = input["yaml_content"]
              return failure("ansible_inventory_yaml_invalid") unless yaml.is_a?(String) && yaml.present? &&
                yaml.bytesize <= ::ControlCenter::Ansible::YamlLimits::MAX_BYTES &&
                Assistant::Context::SecretDetector.safe?(yaml)
              validation = ::ControlCenter::Ansible::InventoryValidator.call(yaml)
              return failure("ansible_inventory_yaml_invalid") unless validation.valid?
              attributes["yaml_content"] = yaml
            end
            if input.key?("default_credential_id")
              id = input["default_credential_id"]
              return failure("ansible_inventory_credential_invalid") unless id.nil? || (id.is_a?(Integer) && id.positive?)
              attributes["default_credential_id"] = id
            end
            ids = input.key?("variable_set_ids") ? input["variable_set_ids"] : nil
            unless ids.nil?
              return failure("ansible_variable_set_ids_invalid") unless ids.is_a?(Array) && ids.length <= 100 &&
                ids.all? { |id| id.is_a?(Integer) && id.positive? } && ids.uniq.length == ids.length
            end
            Result.new(valid: true, attributes: attributes.freeze, variable_set_ids: ids&.freeze, codes: [])
          rescue NoMethodError
            failure("ansible_inventory_invalid")
          end

          def failure(code)
            Result.new(valid: false, attributes: nil, variable_set_ids: nil, codes: [ code ])
          end
          private_class_method :failure
        end
      end
    end
  end
end
