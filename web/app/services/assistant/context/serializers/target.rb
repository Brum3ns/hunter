module Assistant
  module Context
    module Serializers
      class Target < Base
        def self.call(record)
          new.call(record)
        end

        def call(record)
          compact(
            id: optional_text(record.id, max: 255),
            url: safe_url(record.url),
            host: optional_text(record.host, max: 255),
            port: integer(record.port),
            scheme: optional_text(record.scheme, max: 12),
            path: clean_path(record.path),
            method: optional_text(record.verb, max: 16)&.upcase,
            status: integer(record.status_code),
            title: optional_text(record.title, max: 500, plain: true),
            webserver: optional_text(record.webserver, max: 200, plain: true),
            tech: string_list(record.tech, count: 50),
            program: optional_text(record.program, max: 255)
          )
        end

        private

        def integer(value)
          Integer(value)
        rescue ArgumentError, TypeError
          nil
        end

        def clean_path(value)
          optional_text(value.to_s.split(/[?#]/, 2).first, max: 2_048)
        end
      end
    end
  end
end
