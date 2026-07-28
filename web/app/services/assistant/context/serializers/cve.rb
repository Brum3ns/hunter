module Assistant
  module Context
    module Serializers
      class Cve < Base
        def self.call(record)
          new.call(record)
        end

        def call(record)
          core = record.as_core_json.slice(*::Cve::CORE_FIELDS)
          result = core.each_with_object({}) do |(key, value), output|
            output[key.to_sym] = bounded_structure(value)
          end
          result[:chain] = bounded_structure(record.chain)
          result
        end
      end
    end
  end
end
