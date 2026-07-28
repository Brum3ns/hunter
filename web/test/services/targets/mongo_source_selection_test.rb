require "test_helper"

class Targets::MongoSourceSelectionTest < ActiveSupport::TestCase
  # A fake Mongo collection view: records the filter it was queried with and
  # replays canned docs / count.
  class FakeCollection
    attr_reader :last_filter
    def initialize(docs) = (@docs = docs)
    def find(filter = {})
      @last_filter = filter
      self
    end
    def projection(_spec) = self
    def each(&blk) = @docs.each(&blk)
    def count_documents(filter) = (@last_filter = filter; @docs.size)
  end

  def with_docs(docs)
    fake = FakeCollection.new(docs)
    stub_methods(Targets::MongoSource, collection: fake) { yield fake }
  end

  test "each_host yields target.host for every matching doc" do
    with_docs([{ "target" => { "host" => "a.example.com" } },
               { "target" => { "host" => "b.example.com" } }]) do
      hosts = []
      Targets::MongoSource.each_host { |h| hosts << h }
      assert_equal %w[a.example.com b.example.com], hosts
    end
  end

  test "each_host skips blank hosts and returns an Enumerator without a block" do
    with_docs([{ "target" => { "host" => "" } }, { "target" => { "host" => "c.example.com" } }]) do
      assert_kind_of Enumerator, Targets::MongoSource.each_host
      assert_equal %w[c.example.com], Targets::MongoSource.each_host.to_a
    end
  end

  test "ids build an _id $in filter; exclude_ids build $nin" do
    oid = BSON::ObjectId.new
    with_docs([]) do |fake|
      Targets::MongoSource.each_host(ids: [oid.to_s]) { }
      assert_equal({ "_id" => { "$in" => [oid] } }, fake.last_filter)
    end
    with_docs([]) do |fake|
      Targets::MongoSource.each_host(q: "nginx", exclude_ids: [oid.to_s]) { }
      assert_includes fake.last_filter["$and"], { "_id" => { "$nin" => [oid] } }
    end
  end

  test "count_hosts returns the matching document count" do
    with_docs([{ "target" => { "host" => "a" } }, { "target" => { "host" => "b" } }]) do
      assert_equal 2, Targets::MongoSource.count_hosts(q: "example")
    end
  end

  test "each_host returns false and logs on Mongo::Error" do
    raising = Object.new
    def raising.find(*) = raise(Mongo::Error.new("boom"))
    stub_methods(Targets::MongoSource, collection: raising) do
      assert_equal false, Targets::MongoSource.each_host { }
    end
  end
end
