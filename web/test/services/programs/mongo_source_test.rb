require "test_helper"

class Programs::MongoSourceTest < ActiveSupport::TestCase
  test "COLLECTION defaults to scope" do
    assert_equal "scope", Programs::MongoSource::COLLECTION
  end

  test "collection delegates to HunterMongo with the configured name" do
    fake = Object.new
    name = Programs::MongoSource::COLLECTION
    stub_methods(HunterMongo, collection: ->(n) { n == name ? fake : nil }) do
      assert_same fake, Programs::MongoSource.collection
    end
  end

  test "ensure_indexes_once! passes COLLECTION and INDEXES to HunterMongo" do
    seen = nil
    stub_methods(HunterMongo, ensure_indexes_once!: ->(n, idx) { seen = [n, idx]; true }) do
      assert Programs::MongoSource.ensure_indexes_once!
    end
    assert_equal [Programs::MongoSource::COLLECTION, Programs::MongoSource::INDEXES], seen
  end
end
