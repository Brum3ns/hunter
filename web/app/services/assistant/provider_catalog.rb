require "yaml"

module Assistant
  module ProviderCatalog
    Entry = Data.define(
      :slug,
      :provider,
      :model,
      :secret_ref,
      :secret_env,
      :input_limit,
      :output_limit,
      :retention_posture
    )

    module_function

    def entries
      @entries ||= load_entries.freeze
    end

    def fetch!(slug)
      entries.fetch(slug.to_s)
    end

    def load_entries
      raw_catalog.each_with_object({}) do |(slug, attributes), result|
        attributes = attributes.stringify_keys
        result[slug.to_s] = Entry.new(
          slug: slug.to_s,
          provider: attributes.fetch("provider"),
          model: attributes.fetch("model"),
          secret_ref: attributes.fetch("secret_ref"),
          secret_env: attributes.fetch("secret_env"),
          input_limit: Integer(attributes.fetch("input_limit")),
          output_limit: Integer(attributes.fetch("output_limit")),
          retention_posture: attributes.fetch("retention_posture")
        ).freeze
      end
    end
    private_class_method :load_entries

    def raw_catalog
      YAML.safe_load_file(
        Rails.root.join("config/assistant_provider_catalog.yml"),
        aliases: false
      ).to_h
    end
    private_class_method :raw_catalog
  end
end
