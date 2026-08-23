module Assistant
  class CapabilityCoverage
    class CoverageError < StandardError; end

    HTTP_METHODS = %w[get post patch put delete].freeze

    class << self
      def verify!(catalog:, route_operations:, openapi_operations:)
        actual = (route_operations + openapi_operations).map { |operation| normalize_operation(operation) }.uniq.sort
        classified = catalog.api_classifications.keys.map { |operation| normalize_operation(operation) }.uniq.sort

        missing = actual - classified
        raise CoverageError, "unclassified API operations: #{missing.join(', ')}" if missing.any?

        stale = classified - actual
        raise CoverageError, "classifications without API operations: #{stale.join(', ')}" if stale.any?

        verify_enabled_tools!(catalog)
        true
      end

      def normalize_operation(operation)
        method, raw_path = operation.to_s.strip.split(/\s+/, 2)
        path = raw_path.to_s.sub(/\(\.\:format\)\z/, "")
        path = path.gsub(/:([a-zA-Z_][a-zA-Z0-9_]*)/, '{\\1}')
        "#{method.to_s.upcase} #{path}"
      end

      def route_operations(routes: Rails.application.routes.routes)
        routes.filter_map do |route|
          path = route.path.spec.to_s
          next unless path.start_with?("/api/v1/")

          route.verb.to_s.split("|").map { |verb| normalize_operation("#{verb} #{path}") }
        end.flatten.uniq.sort
      end

      def openapi_operations(directory: Rails.root.join("config/openapi"))
        Dir[directory.join("*.yaml")].sort.flat_map do |path|
          document = YAML.safe_load_file(path, permitted_classes: [], aliases: false)
          document.fetch("paths", {}).flat_map do |api_path, definition|
            definition.keys.filter_map do |method|
              normalize_operation("#{method} #{api_path}") if HTTP_METHODS.include?(method)
            end
          end
        end.uniq.sort
      end

      private

      def verify_enabled_tools!(catalog)
        names = catalog.tools.map { |tool| tool.fetch("name") }
        catalog.api_classifications.each do |operation, entry|
          next unless entry.fetch("classification") == "enabled"
          next if names.include?(entry.fetch("tool"))

          raise CoverageError, "enabled API operation has no catalog tool: #{operation}"
        end
      end
    end
  end
end
