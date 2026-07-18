module Sitemap
  # Projection of a crawled/archived endpoint URL, deduped per target by
  # (target_id, url_digest). `target_id` is nil while unmatched. Provenance is
  # tracked per source so `source` and tombstoning stay precise.
  class Endpoint < ApplicationRecord
    self.table_name = "sitemap_endpoints"

    belongs_to :target, optional: true, class_name: "Sitemap::Target", inverse_of: :endpoints

    scope :active, -> { where(removed_at: nil) }
    scope :tombstoned, -> { where.not(removed_at: nil) }
    scope :unmatched, -> { where(target_id: nil) }

    def self.derive_source(katana_id, wayback_id)
      return "both" if katana_id.present? && wayback_id.present?
      return "katana" if katana_id.present?
      return "wayback" if wayback_id.present?
      nil
    end
  end
end
