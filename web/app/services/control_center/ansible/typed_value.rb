require "json"

module ControlCenter
  module Ansible
    module TypedValue
      class Error < StandardError; end

      MAX_DEPTH = 20
      MAX_NODES = 2_000

      module_function

      def load(serialized, type:)
        value = JSON.parse(serialized.to_s)
        validate!(value, type: type)
        value
      rescue JSON::ParserError
        raise Error, "must contain valid JSON"
      end

      def dump(value, type:)
        value = parse_collection_fragment(value) if value.is_a?(String) && %w[list dictionary].include?(type.to_s)
        validate!(value, type: type)
        JSON.generate(value)
      rescue JSON::GeneratorError
        raise Error, "must contain only JSON values"
      end

      def validate!(value, type:)
        valid = case type.to_s
        when "string" then value.is_a?(String)
        when "number" then json_number?(value)
        when "boolean" then value == true || value == false
        when "list" then value.is_a?(Array)
        when "dictionary" then value.is_a?(Hash) && value.keys.all? { |key| key.is_a?(String) }
        else false
        end
        raise Error, "must be a #{type}" unless valid

        inspect_json_tree!(value)
      end
      private_class_method :validate!

      def parse_collection_fragment(source)
        result = YamlDocument.call(source)
        raise Error, result.errors.first unless result.valid?

        result.document
      end
      private_class_method :parse_collection_fragment

      def json_number?(value)
        value.is_a?(Integer) || (value.is_a?(Float) && value.finite?)
      end
      private_class_method :json_number?

      def inspect_json_tree!(value)
        count = 0
        stack = [ [ value, 1 ] ]

        until stack.empty?
          current, depth = stack.pop
          count += 1
          raise Error, "exceeds the maximum node count of #{MAX_NODES}" if count > MAX_NODES
          raise Error, "exceeds the maximum depth of #{MAX_DEPTH}" if depth > MAX_DEPTH

          case current
          when String, TrueClass, FalseClass, NilClass
            next
          when Integer
            next
          when Float
            raise Error, "must contain only finite numbers" unless current.finite?
          when Array
            current.reverse_each { |child| stack << [ child, depth + 1 ] }
          when Hash
            current.to_a.reverse_each do |key, child|
              raise Error, "dictionary keys must be strings" unless key.is_a?(String)

              stack << [ child, depth + 1 ]
              stack << [ key, depth + 1 ]
            end
          else
            raise Error, "must contain only JSON values"
          end
        end
      end
      private_class_method :inspect_json_tree!
    end
  end
end
