class SimplifySitemapEndpointsToCrawlSource < ActiveRecord::Migration[8.1]
  # Endpoints now come from a single `crawl` collection instead of separate
  # katana + wayback collections, so the per-source provenance columns and the
  # derived `source` column are replaced by one `crawl_mongo_id`.
  def change
    add_column :sitemap_endpoints, :crawl_mongo_id, :string

    remove_column :sitemap_endpoints, :katana_mongo_id, :string
    remove_column :sitemap_endpoints, :wayback_mongo_id, :string
    remove_column :sitemap_endpoints, :source, :string, null: false
  end
end
