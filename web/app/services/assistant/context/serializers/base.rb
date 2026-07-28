require "uri"

module Assistant
  module Context
    module Serializers
      class Base
        private

        def text(value, max: 2_000, plain: false)
          string = value.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "�")
          string = ActionView::Base.full_sanitizer.sanitize(string) if plain
          string = string.gsub(/[[:space:]]+/, " ").strip if plain
          string.first(max)
        end

        def optional_text(value, **options)
          return if value.blank?

          text(value, **options)
        end

        def string_list(value, count: 30, length: 200)
          Array(value).first(count).filter_map do |item|
            normalized = optional_text(item, max: length, plain: true)
            normalized if normalized.present?
          end
        end

        def safe_url(value)
          uri = URI.parse(value.to_s)
          scheme = uri.scheme.to_s.downcase
          return unless %w[http https].include?(scheme) && uri.host.present?

          default_port = (scheme == "https" ? 443 : 80)
          host = uri.host.include?(":") ? "[#{uri.host}]" : uri.host
          authority = uri.port == default_port ? host : "#{host}:#{uri.port}"
          path = text(uri.path.presence || "/", max: 2_048)
          "#{scheme}://#{authority}#{path}"
        rescue URI::Error
          nil
        end

        def timestamp(value)
          value&.iso8601
        rescue NoMethodError
          optional_text(value, max: 64)
        end

        def compact(hash)
          hash.compact
        end

        def bounded_structure(value, depth: 0)
          return nil if depth > 4

          case value
          when Hash
            value.first(30).to_h.each_with_object({}) do |(key, child), result|
              normalized_key = text(key, max: 64).gsub(/[^A-Za-z0-9_.-]/, "_").to_sym
              result[normalized_key] = bounded_structure(child, depth: depth + 1)
            end
          when Array
            value.first(50).map { |child| bounded_structure(child, depth: depth + 1) }
          when String
            text(value, max: 4_096)
          when Numeric, TrueClass, FalseClass, NilClass
            value
          when Time, Date, DateTime
            value.iso8601
          else
            text(value, max: 512, plain: true)
          end
        end
      end
    end
  end
end
