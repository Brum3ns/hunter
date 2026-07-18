module Sitemap
  # Relational projection of one `alive` asset (one origin). The rich asset
  # detail stays in Mongo (read via Targets::MongoSource); this row owns only
  # the relation. Keyed by the stable natural key `origin`.
  class Target < ApplicationRecord
    self.table_name = "sitemap_targets"

    has_many :endpoints, class_name: "Sitemap::Endpoint",
             foreign_key: :target_id, dependent: :destroy, inverse_of: :target

    scope :active, -> { where(removed_at: nil) }
    scope :tombstoned, -> { where.not(removed_at: nil) }

    def tombstone!(at)
      update!(removed_at: at)
    end
  end
end
