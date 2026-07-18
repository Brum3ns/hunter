require "test_helper"

module Sitemap
  class SchemaTest < ActiveSupport::TestCase
    def conn = ActiveRecord::Base.connection

    test "sitemap tables exist" do
      assert conn.table_exists?(:sitemap_targets)
      assert conn.table_exists?(:sitemap_endpoints)
      assert conn.table_exists?(:mongo_stream_cursors)
    end

    test "endpoints target_id is nullable and cascades" do
      col = conn.columns(:sitemap_endpoints).find { |c| c.name == "target_id" }
      assert col.null, "target_id must be nullable for the unmatched bucket"
    end

    test "origin is unique on targets" do
      idx = conn.indexes(:sitemap_targets).find { |i| i.columns == ["origin"] }
      assert idx&.unique, "targets.origin must be unique"
    end
  end
end
