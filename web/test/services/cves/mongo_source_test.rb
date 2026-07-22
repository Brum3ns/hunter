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
    attr_reader :last_filter, :query, :upserts, :count_result, :last_pipeline
    def initialize(docs = [], count_result: 0, agg_rows: []) = (@docs = docs; @upserts = []; @count_result = count_result; @agg_rows = agg_rows)
    def aggregate(pipeline)
      @last_pipeline = pipeline
      @agg_rows
    end
    def find(filter = {})
      @last_filter = filter
      @query = FakeQuery.new(@docs)
    end
    def update_one(filter, update, opts = {})
      @upserts << { filter:, update:, opts: }
      Struct.new(:matched_count).new(0)
    end
    def count_documents(filter = {})
      @last_filter = filter
      @count_result
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

  test "all builds a case-insensitive search across id, summary and details" do
    collection = FakeCollection.new([])
    with_collection(collection) do
      Cves::MongoSource.all(search: "xss", limit: 10)
      assert_equal(
        [{ "id" => { "$regex" => "xss", "$options" => "i" } },
         { "summary" => { "$regex" => "xss", "$options" => "i" } },
         { "details" => { "$regex" => "xss", "$options" => "i" } }],
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

  test "has_fix filter keeps a literal boolean false" do
    collection = FakeCollection.new([])
    with_collection(collection) do
      Cves::MongoSource.all(filters: { "has_fix" => false }, limit: 10)
      assert_equal({ "has_fix" => false }, collection.last_filter)
    end
  end

  test "has_fix filter casts string false and true" do
    collection = FakeCollection.new([])
    with_collection(collection) do
      Cves::MongoSource.all(filters: { "has_fix" => "false" }, limit: 10)
      assert_equal false, collection.last_filter["has_fix"]

      Cves::MongoSource.all(filters: { "has_fix" => "true" }, limit: 10)
      assert_equal true, collection.last_filter["has_fix"]
    end
  end

  test "published_after and modified_after build $gte filters from ISO-8601 strings" do
    collection = FakeCollection.new([])
    with_collection(collection) do
      Cves::MongoSource.all(filters: { "published_after" => "2026-01-01T00:00:00Z" }, limit: 10)
      assert_equal({ "published" => { "$gte" => Time.iso8601("2026-01-01T00:00:00Z").utc } }, collection.last_filter)

      Cves::MongoSource.all(filters: { "modified_after" => "2026-02-15T12:30:00Z" }, limit: 10)
      assert_equal({ "modified" => { "$gte" => Time.iso8601("2026-02-15T12:30:00Z").utc } }, collection.last_filter)
    end
  end

  test "published_after and modified_after drop unparseable values" do
    collection = FakeCollection.new([])
    with_collection(collection) do
      Cves::MongoSource.all(filters: { "published_after" => "not-a-date" }, limit: 10)
      assert_equal({}, collection.last_filter)

      Cves::MongoSource.all(filters: { "modified_after" => "also-not-a-date" }, limit: 10)
      assert_equal({}, collection.last_filter)
    end
  end

  test "count delegates to count_documents with the built filter" do
    collection = FakeCollection.new([], count_result: 7)
    with_collection(collection) do
      result = Cves::MongoSource.count(filters: { "ecosystem" => "npm" })
      assert_equal 7, result
      assert_equal({ "affected.ecosystem" => "npm" }, collection.last_filter)
    end
  end

  test "new_since filters on first_seen_at and sorts ascending" do
    t = Time.utc(2026, 7, 1)
    collection = FakeCollection.new([{ "id" => "CVE-1" }])
    with_collection(collection) do
      Cves::MongoSource.new_since(since: t, limit: 5)
      assert_equal({ "first_seen_at" => { "$gt" => t } }, collection.last_filter)
      assert_equal({ "first_seen_at" => 1, "id" => 1 }, collection.query.last_sort)
      assert_equal 5, collection.query.last_limit
    end
  end

  test "new_since sorts by (first_seen_at, id) even without a cursor" do
    collection = FakeCollection.new([])
    with_collection(collection) do
      Cves::MongoSource.new_since(limit: 5)
      assert_equal({}, collection.last_filter)
      assert_equal({ "first_seen_at" => 1, "id" => 1 }, collection.query.last_sort)
    end
  end

  test "new_since with since and since_id builds the $or keyset filter" do
    t = Time.utc(2026, 7, 1)
    collection = FakeCollection.new([])
    with_collection(collection) do
      Cves::MongoSource.new_since(since: t, since_id: "CVE-A", limit: 5)
      assert_equal(
        { "$or" => [
            { "first_seen_at" => { "$gt" => t } },
            { "first_seen_at" => t, "id" => { "$gt" => "CVE-A" } }
          ] },
        collection.last_filter
      )
    end
  end

  test "new_since with since only (no since_id) uses a plain $gt filter" do
    t = Time.utc(2026, 7, 1)
    collection = FakeCollection.new([])
    with_collection(collection) do
      Cves::MongoSource.new_since(since: t, limit: 5)
      assert_equal({ "first_seen_at" => { "$gt" => t } }, collection.last_filter)
    end
  end

  test "new_since keyset is lossless across a same-millisecond group" do
    t = Time.utc(2026, 7, 1, 0, 0, 0, 500_000)
    docs = [
      { "id" => "CVE-A", "first_seen_at" => t },
      { "id" => "CVE-B", "first_seen_at" => t },
      { "id" => "CVE-C", "first_seen_at" => t }
    ]
    collection = FakeCollection.new(docs)
    with_collection(collection) do
      # A cursor positioned right after CVE-A (same first_seen_at) must still
      # surface CVE-B and CVE-C via the $or second branch (id > "CVE-A").
      Cves::MongoSource.new_since(since: t, since_id: "CVE-A", limit: 5)
      or_clauses = collection.last_filter["$or"]
      tie_break = or_clauses.find { |clause| clause.key?("id") }
      assert_equal({ "first_seen_at" => t, "id" => { "$gt" => "CVE-A" } }, tie_break)
      # "CVE-B" and "CVE-C" both sort after "CVE-A" lexically, so the $gt
      # comparison the driver would perform on `id` includes both.
      assert_operator "CVE-B", :>, "CVE-A"
      assert_operator "CVE-C", :>, "CVE-A"
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

  test "list filters use $in for multiple comma-separated values" do
    collection = FakeCollection.new([])
    with_collection(collection) do
      Cves::MongoSource.all(filters: { "ecosystem" => "npm,PyPI", "tag" => "cms" }, limit: 10)
      assert_equal({ "$in" => %w[npm PyPI] }, collection.last_filter["affected.ecosystem"])
      assert_equal "cms", collection.last_filter["tags"]
    end
  end

  test "min_severity filters on severity_score floor" do
    collection = FakeCollection.new([])
    with_collection(collection) do
      Cves::MongoSource.all(filters: { "min_severity" => "high" }, limit: 10)
      assert_equal({ "$gte" => 7.0 }, collection.last_filter["severity_score"])
    end
  end

  test "search covers id, summary and details" do
    collection = FakeCollection.new([])
    with_collection(collection) do
      Cves::MongoSource.all(search: "rce", limit: 10)
      fields = collection.last_filter["$or"].flat_map(&:keys)
      assert_equal %w[id summary details], fields
    end
  end

  test "new_since composes extra filters with the cursor via $and" do
    collection = FakeCollection.new([])
    with_collection(collection) do
      Cves::MongoSource.new_since(since: Time.utc(2026, 7, 1), since_id: "CVE-1",
                                  filters: { "language" => "Python" }, limit: 10)
      assert collection.last_filter.key?("$and")
      assert_includes collection.last_filter["$and"], { "languages" => "Python" }
    end
  end

  test "ecosystem_facets unwinds affected and maps rows to ecosystem/count" do
    rows = [{ "_id" => "npm", "count" => 12 }, { "_id" => "PyPI", "count" => 3 }]
    collection = FakeCollection.new(agg_rows: rows)
    with_collection(collection) do
      facets = Cves::MongoSource.ecosystem_facets(limit: 5)
      assert_equal([{ "ecosystem" => "npm", "count" => 12 },
                    { "ecosystem" => "PyPI", "count" => 3 }], facets)
      stages = collection.last_pipeline.map { |s| s.keys.first }
      assert_equal ["$unwind", "$group", "$match", "$sort", "$limit"], stages
      assert_equal 5, collection.last_pipeline.last["$limit"]
    end
  end

  test "ecosystem_facets swallows Mongo::Error and returns empty" do
    boom = FakeCollection.new
    boom.define_singleton_method(:aggregate) { |*| raise Mongo::Error, "down" }
    with_collection(boom) do
      assert_equal [], Cves::MongoSource.ecosystem_facets
    end
  end
end
