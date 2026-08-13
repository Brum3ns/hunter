module Assistant
  module ChatBackend
    SLUGS = %w[codex claude_code].freeze
    BRANDS = { "codex" => "openai", "claude_code" => "anthropic" }.freeze

    module_function

    def fetch(slug)
      value = slug.to_s
      return unless SLUGS.include?(value)

      Assistant::ProviderProfile.where(enabled: true).where.not(reviewed_at: nil)
        .find_by(catalog_slug: value)
    end

    def slug_for(profile)
      profile&.catalog_slug if SLUGS.include?(profile&.catalog_slug)
    end

    def descriptors
      SLUGS.filter_map do |slug|
        profile = fetch(slug)
        next unless profile

        {
          slug: slug,
          brand: BRANDS.fetch(slug),
          name: profile.name,
          enabled: profile.enabled?,
          retention_posture: profile.retention_posture,
          reviewed_at: profile.reviewed_at&.iso8601
        }
      end
    end
  end
end
