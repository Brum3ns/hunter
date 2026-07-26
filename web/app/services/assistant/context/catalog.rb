module Assistant
  module Context
    module Catalog
      MAX_SERIALIZED_BYTES = 32_768

      class UnsafeContentError < StandardError; end
      class TooLargeError < StandardError; end

      SERIALIZERS = {
        "program" => Assistant::Context::Serializers::Program,
        "target" => Assistant::Context::Serializers::Target,
        "cve" => Assistant::Context::Serializers::Cve,
        "vulnerability" => Assistant::Context::Serializers::Vulnerability,
        "whiterabbit_template" => Assistant::Context::Serializers::WhiterabbitTemplate,
        "ansible_playbook" => Assistant::Context::Serializers::AnsiblePlaybook
      }.freeze

      module_function

      def serialize!(type:, record:)
        normalized_type = type.to_s
        serializer = SERIALIZERS.fetch(normalized_type)
        data = serializer.call(record)
        envelope = {
          schema_version: 1,
          type: normalized_type,
          id: data.fetch(:id) { resource_id(record, normalized_type) },
          data: data
        }
        raise TooLargeError, "serialized context exceeds 32 KiB" if
          JSON.generate(envelope).bytesize > MAX_SERIALIZED_BYTES

        envelope
      end

      def resource_id(record, type)
        type == "program" ? record.sid.to_s : record.id.to_s
      end
      private_class_method :resource_id
    end
  end
end
