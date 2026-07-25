module ControlCenter
  module Ansible
    module InventoryValidator
      Result = YamlDocument::Result
      module_function

      def call(yaml)
        parsed = YamlDocument.call(yaml)
        return parsed unless parsed.valid?

        document = parsed.document
        unless document.is_a?(Hash)
          return Result.new(document: document, errors: [ "inventory must be a mapping" ])
        end

        errors = []
        document.each { |name, group| inspect_group(group, name.to_s, errors) }
        inspect_prohibited(document, errors)
        Result.new(document: document, errors: errors)
      end

      def inspect_group(group, path, errors)
        unless group.is_a?(Hash)
          errors << "#{path} must be a mapping"
          return
        end

        %w[hosts children vars].each do |section|
          next unless group.key?(section) && !group[section].is_a?(Hash)

          errors << "#{path}.#{section} must be a mapping"
        end

        if group["hosts"].is_a?(Hash)
          group["hosts"].each do |host, attributes|
            next if attributes.nil?
            unless attributes.is_a?(Hash)
              errors << "#{path}.hosts.#{host} must be a mapping"
              next
            end
            inspect_ports(attributes, "#{path}.hosts.#{host}", errors)
          end
        end

        return unless group["children"].is_a?(Hash)

        group["children"].each do |child_name, child|
          inspect_group(child, "#{path}.children.#{child_name}", errors)
        end
      end
      private_class_method :inspect_group

      def inspect_ports(value, path, errors)
        value.each do |key, child|
          if key.to_s.casecmp?("ansible_port") && !(child.is_a?(Integer) && child.between?(1, 65_535))
            errors << "#{path}.#{key} must be an integer from 1 to 65535"
          end
          inspect_ports(child, "#{path}.#{key}", errors) if child.is_a?(Hash)
        end
      end
      private_class_method :inspect_ports

      def inspect_prohibited(value, errors)
        case value
        when Array
          value.each { |child| inspect_prohibited(child, errors) }
        when Hash
          value.each do |key, child|
            normalized = key.to_s.downcase
            if %w[connection ansible_connection].include?(normalized)
              message = child.to_s.casecmp?("local") ? "#{key}: local is not allowed" : "#{key} is not configurable"
              errors << message
            elsif YamlLimits::RESERVED_CONNECTION_KEYS.include?(normalized)
              errors << "#{key} is a reserved connection variable"
            elsif normalized == "local_action"
              errors << "local_action is not allowed"
            elsif normalized == "delegate_to" && child.to_s.casecmp?("localhost")
              errors << "delegate_to: localhost is not allowed"
            end
            inspect_prohibited(child, errors)
          end
        end
      end
      private_class_method :inspect_prohibited
    end
  end
end
