module Assistant
  module Context
    module Serializers
      class Program < Base
        def self.call(record)
          new.call(record)
        end

        def call(record)
          compact(
            sid: optional_text(record.sid, max: 255),
            name: optional_text(record.name, max: 300, plain: true),
            platform: optional_text(record.platform, max: 80),
            status: optional_text(record.status, max: 80),
            public: record.public?,
            bounty: record.bounty?,
            currency: optional_text(record.currency, max: 12),
            tags: string_list(record.tags),
            languages: string_list(record.languages),
            description: optional_text(record.description, max: 40_000, plain: true)
          )
        end
      end
    end
  end
end
