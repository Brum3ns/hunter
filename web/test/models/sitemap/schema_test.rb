require "test_helper"

module Sitemap
  class SchemaTest < ActiveSupport::TestCase
    def conn = ActiveRecord::Base.connection

    test "sitemap tables exist" do
      assert conn.table_exists?(:sitemap_targets)
      assert conn.table_exists?(:sitemap_endpoints)
      assert conn.table_exists?(:mongo_stream_cursors)
    end

    test "endpoints target_id is nullable" do
      col = conn.columns(:sitemap_endpoints).find { |c| c.name == "target_id" }
      assert col.null, "target_id must be nullable for the unmatched bucket"
    end

    test "deleting a target cascades to its endpoints at the DB level" do
      now = Time.current
      target = Sitemap::Target.create!(origin: "https://cascade.example:443", scheme: "https",
                                        host: "cascade.example", port: 443,
                                        first_seen_at: now, last_seen_at: now)
      endpoint = Sitemap::Endpoint.create!(target_id: target.id, origin: target.origin,
                                            url: "#{target.origin}/a", path: "/a", method: "GET",
                                            source: "katana", url_digest: Sitemap::Origin.digest("#{target.origin}/a", "GET"),
                                            first_seen_at: now, last_seen_at: now)

      # Delete via raw SQL, bypassing AR's `dependent: :destroy`, so this
      # exercises the DB-level ON DELETE CASCADE FK constraint itself.
      conn.execute("DELETE FROM sitemap_targets WHERE id = #{target.id}")

      assert_not Sitemap::Endpoint.exists?(endpoint.id), "ON DELETE CASCADE should have removed the endpoint row"
    end

    test "origin is unique on targets" do
      idx = conn.indexes(:sitemap_targets).find { |i| i.columns == ["origin"] }
      assert idx&.unique, "targets.origin must be unique"
    end
  end
end
