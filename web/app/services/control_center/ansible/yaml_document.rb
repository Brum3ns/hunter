require "psych"

module ControlCenter
  module Ansible
    module YamlDocument
      Result = Data.define(:document, :errors) do
        def valid? = errors.empty?
      end

      PEM_BOUNDARY = /-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/
      module_function

      def call(yaml)
        source = yaml.to_s
        return failure("exceeds the maximum size of #{YamlLimits::MAX_BYTES} bytes") if source.bytesize > YamlLimits::MAX_BYTES

        stream = Psych.parse_stream(source)
        return failure("must contain exactly one YAML document") unless stream.children.one?

        ast_error = inspect_ast(stream)
        return failure(ast_error) if ast_error

        document = Psych.safe_load(
          source, permitted_classes: [], permitted_symbols: [], aliases: false
        )
        limit_error = inspect_limits(document)
        return failure(limit_error) if limit_error

        Result.new(document: document, errors: [])
      rescue Psych::AliasesNotEnabled
        failure("YAML aliases are not allowed")
      rescue Psych::Exception, SystemStackError
        failure("is invalid YAML")
      end

      def inspect_ast(stream)
        count = 0
        stack = [ [ stream, 0 ] ]
        until stack.empty?
          node, depth = stack.pop
          unless node.is_a?(Psych::Nodes::Stream) || node.is_a?(Psych::Nodes::Document)
            count += 1
            return "exceeds the maximum node count of #{YamlLimits::MAX_NODES}" if count > YamlLimits::MAX_NODES
            return "exceeds the maximum depth of #{YamlLimits::MAX_DEPTH}" if depth > YamlLimits::MAX_DEPTH
          end
          return "YAML aliases are not allowed" if node.is_a?(Psych::Nodes::Alias)

          if node.respond_to?(:tag) && node.tag.present? && !node.tag.start_with?("tag:yaml.org,2002:")
            return "Ansible Vault content is not supported" if node.tag.to_s.downcase.include?("vault")
            return "custom YAML tags are not allowed"
          end

          if node.is_a?(Psych::Nodes::Scalar)
            return "Ansible Vault content is not supported" if node.value.to_s.include?("ANSIBLE_VAULT")
            return "embedded private keys are not allowed" if node.value.to_s.match?(PEM_BOUNDARY)
          end

          next unless node.respond_to?(:children) && node.children

          child_depth = node.is_a?(Psych::Nodes::Stream) ? depth : depth + 1
          node.children.reverse_each { |child| stack << [ child, child_depth ] }
        end
        nil
      end
      private_class_method :inspect_ast

      def inspect_limits(document)
        count = 0
        stack = [ [ document, 1 ] ]
        until stack.empty?
          value, depth = stack.pop
          count += 1
          return "exceeds the maximum node count of #{YamlLimits::MAX_NODES}" if count > YamlLimits::MAX_NODES
          return "exceeds the maximum depth of #{YamlLimits::MAX_DEPTH}" if depth > YamlLimits::MAX_DEPTH

          case value
          when Array
            value.reverse_each { |child| stack << [ child, depth + 1 ] }
          when Hash
            value.to_a.reverse_each do |key, child|
              stack << [ child, depth + 1 ]
              stack << [ key, depth + 1 ]
            end
          end
        end
        nil
      end
      private_class_method :inspect_limits

      def failure(message)
        Result.new(document: nil, errors: [ message ])
      end
      private_class_method :failure
    end
  end
end
