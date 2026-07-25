module ControlCenter
  module Ansible
    module PlaybookValidator
      Result = YamlDocument::Result
      TASK_SECTIONS = %w[pre_tasks tasks post_tasks handlers].freeze
      module_function

      def call(yaml)
        parsed = YamlDocument.call(yaml)
        return parsed unless parsed.valid?

        document = parsed.document
        unless document.is_a?(Array) && document.any?
          return Result.new(document: document, errors: [ "playbook must be a non-empty array of plays" ])
        end

        errors = []
        document.each_with_index do |play, index|
          unless play.is_a?(Hash)
            errors << "play #{index + 1} must be a mapping"
            next
          end

          errors << "play #{index + 1} must define non-blank hosts" if play["hosts"].blank?
          TASK_SECTIONS.each do |section|
            next unless play.key?(section) && !play[section].is_a?(Array)

            errors << "play #{index + 1} #{section} must be an array"
          end
        end
        inspect_prohibited(document, errors)
        Result.new(document: document, errors: errors)
      end

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
