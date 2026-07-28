module Assistant
  module Context
    module Serializers
      class AnsiblePlaybook < Base
        def self.call(record)
          new.call(record)
        end

        def call(record)
          payload = compact(
            id: record.id,
            name: optional_text(record.name, max: 200, plain: true),
            description: optional_text(record.description, max: 4_000, plain: true),
            yaml: optional_text(record.yaml_content, max: 40_000),
            checksum: optional_text(record.checksum, max: 64),
            updated_at: timestamp(record.updated_at)
          )
          reject_secrets!(payload)
          payload
        end

        private

        def reject_secrets!(payload)
          reason = Assistant::Context::SecretDetector.detect(payload)
          raise Assistant::Context::Catalog::UnsafeContentError, reason.to_s if reason
        end
      end
    end
  end
end
