module Assistant
  module Context
    module Serializers
      class WhiterabbitTemplate < Base
        def self.call(record)
          new.call(record)
        end

        def call(record)
          payload = compact(
            id: record.id,
            name: optional_text(record.name, max: 200, plain: true),
            kind: optional_text(record.kind, max: 40),
            tags: string_list(record.tags),
            description: optional_text(record.description, max: 4_000, plain: true),
            output: optional_text(record.output, max: 255),
            commands: commands(record.commands),
            target: bounded_structure(record.target),
            updated_at: timestamp(record.updated_at)
          )
          reject_secrets!(payload)
          payload
        end

        private

        def commands(value)
          Array(value).first(50).map do |raw|
            command = raw.to_h.stringify_keys
            compact(
              command: optional_text(command["command"], max: 255),
              args: string_list(command["args"], count: 200, length: 4_096),
              operator: optional_text(command["operator"], max: 4)
            )
          end
        end

        def reject_secrets!(payload)
          reason = Assistant::Context::SecretDetector.detect(payload)
          raise Assistant::Context::Catalog::UnsafeContentError, reason.to_s if reason
        end
      end
    end
  end
end
