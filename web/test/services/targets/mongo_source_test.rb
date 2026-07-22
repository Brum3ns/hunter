require "test_helper"

class Targets::MongoSourceTest < ActiveSupport::TestCase
  class FakeQuery
    def initialize(docs) = @docs = docs
    attr_reader :last_sort
    def sort(spec) = (@last_sort = spec; self)
    def skip(*) = self
    def limit(*) = self
    def to_a = @docs
  end

  class FakeCollection
    attr_reader :last_filter, :query
    def initialize(docs) = @docs = docs
    def find(filter = {})
      @last_filter = filter
      @query = FakeQuery.new(@docs)
    end
  end

  test "all normalizes documents and defaults to date-desc sort" do
    oid = BSON::ObjectId.new
    collection = FakeCollection.new([{ "_id" => oid, "target" => { "host" => "a" } }])

    stub_methods(HunterMongo, ensure_indexes_once!: true, collection: collection) do
      result = Targets::MongoSource.all(limit: 10)
      assert_equal oid.to_s, result.first["id"]
      assert_not result.first.key?("_id")
      assert_equal({ "metadata.date" => -1 }, collection.query.last_sort)
    end
  end

  test "all maps a whitelisted sort key and ascending direction" do
    collection = FakeCollection.new([])
    stub_methods(HunterMongo, ensure_indexes_once!: true, collection: collection) do
      Targets::MongoSource.all(sort: "host", dir: "asc", limit: 10)
      assert_equal({ "target.host" => 1 }, collection.query.last_sort)
    end
  end

  test "all builds a search $or across host, ip, title and tech" do
    collection = FakeCollection.new([])
    stub_methods(HunterMongo, ensure_indexes_once!: true, collection: collection) do
      Targets::MongoSource.all(search: "nginx", limit: 10)
      assert_equal(
        [
          { "target.host" => { "$regex" => "nginx", "$options" => "i" } },
          { "target.ip"   => { "$regex" => "nginx", "$options" => "i" } },
          { "http.title"  => { "$regex" => "nginx", "$options" => "i" } },
          { "tech"        => { "$regex" => "nginx", "$options" => "i" } }
        ],
        collection.last_filter["$or"]
      )
    end
  end

  test "all maps allowed filters and drops blanks and unknowns" do
    collection = FakeCollection.new([])
    stub_methods(HunterMongo, ensure_indexes_once!: true, collection: collection) do
      Targets::MongoSource.all(filters: { "program" => "acme", "nope" => "x", "status" => "" }, limit: 10)
      assert_equal({ "metadata.program" => "acme" }, collection.last_filter)
    end
  end

  test "all swallows Mongo errors and returns an empty array" do
    stub_methods(HunterMongo, ensure_indexes_once!: true, collection: ->(*) { raise Mongo::Error.new("down") }) do
      assert_equal [], Targets::MongoSource.all(limit: 10)
    end
  end

  test "find returns nil for a malformed id without hitting Mongo" do
    assert_nil Targets::MongoSource.find("not-an-oid")
  end

  test "all applies a dork expression as the sole filter when nothing else is set" do
    collection = FakeCollection.new([])
    expr = Targets::DorkExpression::Term.new(key: "status", op: ">=", value: "500")
    stub_methods(HunterMongo, ensure_indexes_once!: true, collection: collection) do
      Targets::MongoSource.all(expression: expr, limit: 10)
      assert_equal({ "http.status_code" => { "$gte" => 500 } }, collection.last_filter)
    end
  end

  test "all combines free text and a dork expression under $and" do
    collection = FakeCollection.new([])
    expr = Targets::DorkExpression::Term.new(key: "host", op: nil, value: "acme")
    stub_methods(HunterMongo, ensure_indexes_once!: true, collection: collection) do
      Targets::MongoSource.all(search: "nginx", expression: expr, limit: 10)
      clauses = collection.last_filter["$and"]
      assert_equal 2, clauses.length
      assert clauses.any? { |c| c.key?("$or") }
      assert_includes clauses, { "target.host" => { "$regex" => "acme", "$options" => "i" } }
    end
  end

  test "count accepts an expression" do
    collection = Object.new
    captured = nil
    collection.define_singleton_method(:count_documents) { |f| captured = f; 3 }
    expr = Targets::DorkExpression::Term.new(key: "status", op: nil, value: "200")
    stub_methods(HunterMongo, collection: collection) do
      assert_equal 3, Targets::MongoSource.count(expression: expr)
      assert_equal({ "http.status_code" => 200 }, captured)
    end
  end
end
