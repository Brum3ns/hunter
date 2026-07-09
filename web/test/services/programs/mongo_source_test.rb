require "test_helper"

class Programs::MongoSourceTest < ActiveSupport::TestCase
  test "COLLECTION is programs" do
    assert_equal "programs", Programs::MongoSource::COLLECTION
  end

  test "collection delegates to HunterMongo with the programs name" do
    fake = Object.new
    stub_methods(HunterMongo, collection: ->(name) { name == "programs" ? fake : nil }) do
      assert_same fake, Programs::MongoSource.collection
    end
  end

  test "ensure_indexes_once! passes COLLECTION and INDEXES to HunterMongo" do
    seen = nil
    stub_methods(HunterMongo, ensure_indexes_once!: ->(name, idx) { seen = [name, idx]; true }) do
      assert Programs::MongoSource.ensure_indexes_once!
    end
    assert_equal ["programs", Programs::MongoSource::INDEXES], seen
  end
end
