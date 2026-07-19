module Sitemap
  # Projection of a crawled endpoint URL, deduped per target by
  # (target_id, url_digest). `target_id` is nil while unmatched; `crawl_mongo_id`
  # is the source doc's id, used to tombstone the row on a change-stream delete.
  class Endpoint < ApplicationRecord
    self.table_name = "sitemap_endpoints"

    belongs_to :target, optional: true, class_name: "Sitemap::Target", inverse_of: :endpoints

    scope :active, -> { where(removed_at: nil) }
    scope :tombstoned, -> { where.not(removed_at: nil) }
    scope :unmatched, -> { where(target_id: nil) }
  end
end
