module Cves
  # Assigns curated "technology" tags (cms, plugin, web, ...) to a CVE by
  # matching package names, vendors, and ecosystems against RULES. OSV has no
  # technology field, so this is Hunter's own mapping — extend RULES to grow
  # coverage. Pure; unmatched input yields [].
  module Tagger
    module_function

    RULES = [
      { pattern: /wordpress|wp-|woocommerce/i, tags: %w[cms] },
      { pattern: /drupal/i,                    tags: %w[cms] },
      { pattern: /joomla/i,                    tags: %w[cms] },
      { pattern: /magento/i,                   tags: %w[cms ecommerce] }
    ].freeze

    def call(ecosystems:, affected:, vendors:)
      haystack = [
        *Array(ecosystems),
        *Array(vendors),
        *Array(affected).map { |a| a.to_h["package"] }
      ].compact.join(" ")

      RULES.each_with_object([]) do |rule, tags|
        tags.concat(rule[:tags]) if haystack.match?(rule[:pattern])
      end.uniq
    end
  end
end
