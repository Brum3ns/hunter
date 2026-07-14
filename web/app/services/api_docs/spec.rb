require "yaml"

# Builds Hunter's OpenAPI document by deep-merging config/openapi/base.yaml with
# one YAML fragment per module. The document is filtered to a caller's token
# scopes so a scoped bearer token downloads only the endpoints it may use.
#
# Adding a module later is a drop-in: create config/openapi/<module>.yaml. This
# service never needs editing. Fragment basename == module slug == scope slug.
module ApiDocs
  module Spec
    module_function

    DEFAULT_DIR = -> { Rails.root.join("config", "openapi") }

    class DuplicateKeyError < StandardError; end

    # Returns the merged OpenAPI document (a Hash with string keys).
    # scopes: nil or a list containing "*" -> all fragments; otherwise only
    # fragments whose file basename is listed.
    def document(scopes: nil, dir: nil)
      dir = Pathname(dir || DEFAULT_DIR.call)
      return build(dir, scopes) if Rails.env.development?

      @cache ||= {}
      @cache[[dir.to_s, cache_key(scopes)]] ||= build(dir, scopes)
    end

    def cache_key(scopes)
      scopes.nil? ? "*" : scopes.sort.join(",")
    end

    def build(dir, scopes)
      doc = load_yaml(dir.join("base.yaml"))
      doc["paths"] ||= {}
      doc["components"] ||= {}
      doc["components"]["schemas"] ||= {}

      fragment_files(dir, scopes).each do |file|
        fragment = load_yaml(file)
        merge_section!(doc["paths"], fragment["paths"], file, "paths")
        schemas = fragment.dig("components", "schemas")
        merge_section!(doc["components"]["schemas"], schemas, file, "schemas")
      end
      doc
    end

    # Every *.yaml except base.yaml, filtered by scope. All fragments when
    # scopes is nil or contains "*".
    def fragment_files(dir, scopes)
      all = Dir.glob(dir.join("*.yaml")).reject { |f| File.basename(f) == "base.yaml" }.sort
      return all if scopes.nil? || scopes.include?("*")

      wanted = Array(scopes).map(&:to_s)
      all.select { |f| wanted.include?(File.basename(f, ".yaml")) }
    end

    def merge_section!(into, from, file, label)
      return if from.nil?

      from.each do |key, value|
        if into.key?(key)
          raise DuplicateKeyError, "duplicate #{label} key #{key.inspect} in #{File.basename(file)}"
        end
        into[key] = value
      end
    end

    def load_yaml(path)
      YAML.safe_load(File.read(path), aliases: true) || {}
    end
  end
end
