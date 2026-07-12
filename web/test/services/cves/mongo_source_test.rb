require "test_helper"

class Cves::MongoSourceTest < ActiveSupport::TestCase
  class FakeQuery
    def initialize(docs) = @docs = docs
    attr_reader :last_sort, :last_limit
    def sort(spec) = (@last_sort = spec; self)
    def skip(*) = self
    def limit(n) = (@last_limit = n; self)
    def first = @docs.first
    def to_a = @docs
  end

  class FakeCollection
    attr_reader :last_filter, :query, :upserts
    def initialize(docs = []) = (@docs = docs; @upserts = [])
    def find(filter = {})
      @last_filter = filter
      @query = FakeQuery.new(@docs)
    end
    def update_one(filter, update, opts = {})
      @upserts << { filter:, update:, opts: }
      Struct.new(:matched_count).new(0)
    end
  end

  def with_collection(collection)
    stub_methods(HunterMongo, ensure_indexes_once!: true, collection: collection) { yield }
  end

  test "all sorts by modified desc and strips _id" do
    oid = BSON::ObjectId.new
    collection = FakeCollection.new([{ "_id" => oid, "id" => "CVE-1", "summary" => "x" }])
    with_collection(collection) do
      result = Cves::MongoSource.all(limit: 10)
      assert_equal "CVE-1", result.first["id"]
      assert_not result.first.key?("_id")
      assert_equal({ "modified" => -1 }, collection.query.last_sort)
    end
  end

  test "all maps ecosystem/package filters and drops unknowns" do
    collection = FakeCollection.new([])
    with_collection(collection) do
      Cves::MongoSource.all(filters: { "ecosystem" => "npm", "bogus" => "x" }, limit: 10)
      assert_equal({ "affected.ecosystem" => "npm" }, collection.last_filter)
    end
  end

  test "all builds a case-insensitive search across id and summary" do
    collection = FakeCollection.new([])
    with_collection(collection) do
      Cves::MongoSource.all(search: "xss", limit: 10)
      assert_equal(
        [{ "id" => { "$regex" => "xss", "$options" => "i" } },
         { "summary" => { "$regex" => "xss", "$options" => "i" } }],
        collection.last_filter["$or"]
      )
    end
  end

  test "has_fix filter passes a boolean through" do
    collection = FakeCollection.new([])
    with_collection(collection) do
      Cves::MongoSource.all(filters: { "has_fix" => "true" }, limit: 10)
      assert_equal true, collection.last_filter["has_fix"]
    end
  end

  test "new_since filters on first_seen_at and sorts ascending" do
    t = Time.utc(2026, 7, 1)
    collection = FakeCollection.new([{ "id" => "CVE-1" }])
    with_collection(collection) do
      Cves::MongoSource.new_since(since: t, limit: 5)
      assert_equal({ "first_seen_at" => { "$gt" => t } }, collection.last_filter)
      assert_equal({ "first_seen_at" => 1 }, collection.query.last_sort)
      assert_equal 5, collection.query.last_limit
    end
  end

  test "find looks up by the string id field" do
    collection = FakeCollection.new([{ "id" => "CVE-1", "summary" => "x" }])
    with_collection(collection) do
      assert_equal "CVE-1", Cves::MongoSource.find("CVE-1")["id"]
      assert_equal({ "id" => "CVE-1" }, collection.last_filter)
    end
  end

  test "upsert sets fields plus last_synced_at and setOnInsert first_seen_at" do
    collection = FakeCollection.new
    with_collection(collection) do
      id = Cves::MongoSource.upsert("id" => "CVE-9", "summary" => "x", "first_seen_at" => "IGNORED")
      assert_equal "CVE-9", id
      op = collection.upserts.first
      assert_equal({ "id" => "CVE-9" }, op[:filter])
      assert_equal true, op[:opts][:upsert]
      assert_equal "x", op[:update]["$set"]["summary"]
      assert op[:update]["$set"]["last_synced_at"].is_a?(Time)
      assert_not op[:update]["$set"].key?("first_seen_at")
      assert op[:update]["$setOnInsert"]["first_seen_at"].is_a?(Time)
    end
  end

  test "reads swallow Mongo::Error and return empty results" do
    boom = FakeCollection.new
    boom.define_singleton_method(:find) { |*| raise Mongo::Error, "down" }
    with_collection(boom) do
      assert_equal [], Cves::MongoSource.all(limit: 10)
      assert_nil Cves::MongoSource.find("CVE-1")
      assert_equal [], Cves::MongoSource.new_since
    end
  end
end
