require "test_helper"

class Sitemap::MongoSourceTest < ActiveSupport::TestCase
  class FakeCollection
    def initialize(docs) = @docs = docs
    def find = @docs
  end

  test "each_katana yields every doc from the collection" do
    fake = FakeCollection.new([{ "_id" => 1 }, { "_id" => 2 }])
    stub_methods(HunterMongo, collection: ->(name) { assert_equal Sitemap::MongoSource::KATANA, name; fake }) do
      seen = []
      Sitemap::MongoSource.each_katana { |d| seen << d["_id"] }
      assert_equal [1, 2], seen
    end
  end

  test "reads swallow Mongo::Error" do
    stub_methods(HunterMongo, collection: ->(_n) { raise Mongo::Error.new("down") }) do
      assert_nothing_raised { Sitemap::MongoSource.each_alive { |_d| flunk "should not yield" } }
    end
  end
end
