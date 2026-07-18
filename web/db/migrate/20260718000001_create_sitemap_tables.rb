class CreateSitemapTables < ActiveRecord::Migration[8.1]
  def change
    create_table :sitemap_targets do |t|
      t.string   :origin, null: false
      t.string   :scheme, null: false
      t.string   :host,   null: false
      t.integer  :port,   null: false
      t.string   :program
      t.string   :alive_mongo_id
      t.datetime :first_seen_at, null: false
      t.datetime :last_seen_at,  null: false
      t.datetime :removed_at
      t.timestamps
    end
    add_index :sitemap_targets, :origin, unique: true
    add_index :sitemap_targets, :host
    add_index :sitemap_targets, :program
    add_index :sitemap_targets, :removed_at

    create_table :sitemap_endpoints do |t|
      t.references :target, foreign_key: { to_table: :sitemap_targets, on_delete: :cascade }, null: true
      t.string   :origin, null: false
      t.text     :url,    null: false
      t.text     :path,   null: false
      t.string   :method, null: false
      t.string   :source, null: false
      t.integer  :status_code
      t.bigint   :content_length
      t.string   :content_type
      t.binary   :url_digest, null: false
      t.string   :katana_mongo_id
      t.string   :wayback_mongo_id
      t.datetime :first_seen_at, null: false
      t.datetime :last_seen_at,  null: false
      t.datetime :removed_at
      t.timestamps
    end
    add_index :sitemap_endpoints, %i[target_id url_digest], unique: true,
              name: "idx_sitemap_endpoints_matched_digest"
    add_index :sitemap_endpoints, %i[origin url_digest], unique: true,
              where: "target_id IS NULL", name: "idx_sitemap_endpoints_unmatched_digest"
    add_index :sitemap_endpoints, %i[target_id path]
    add_index :sitemap_endpoints, %i[target_id removed_at]
    add_index :sitemap_endpoints, :origin, where: "target_id IS NULL",
              name: "idx_sitemap_endpoints_unmatched_origin"

    create_table :mongo_stream_cursors do |t|
      t.string :collection, null: false
      t.jsonb  :resume_token, null: false, default: {}
      t.timestamps
    end
    add_index :mongo_stream_cursors, :collection, unique: true
  end
end
