require "test_helper"

class Vulnerabilities::MongoSourceTest < ActiveSupport::TestCase
  # Minimal chainable stand-ins for the Mongo driver's query + collection so the
  # suite never needs a live Mongo (mirrors scope-ui's approach).
  class FakeQuery
    def initialize(docs) = @docs = docs
    def sort(*) = self
    def skip(*) = self
    def limit(*) = self
    def to_a = @docs
  end

  class FakeCollection
    attr_reader :last_filter

    def initialize(docs) = @docs = docs
    def find(filter = {})
      @last_filter = filter
      FakeQuery.new(@docs)
    end
  end

  test "all builds a nested mongo filter and normalizes the documents" do
    oid = BSON::ObjectId.new
    collection = FakeCollection.new([{ "_id" => oid, "finding" => { "severity" => "low" } }])

    stub_methods(HunterMongo, ensure_indexes_once!: true, collection: collection) do
      result = Vulnerabilities::MongoSource.all(
        filters: { "severity" => "low", "unknown" => "x" }, page: 2, limit: 10
      )

      assert_equal({ "finding.severity" => "low" }, collection.last_filter)
      assert_equal oid.to_s, result.first["id"]
      assert_not result.first.key?("_id")
    end
  end

  test "all swallows Mongo errors and returns an empty array" do
    stub_methods(HunterMongo, ensure_indexes_once!: true, collection: ->(*) { raise Mongo::Error.new("unreachable") }) do
      assert_equal [], Vulnerabilities::MongoSource.all(limit: 10)
    end
  end

  test "normalize maps _id to a string id and stringifies keys" do
    oid = BSON::ObjectId.new
    out = Vulnerabilities::MongoSource.send(:normalize, { _id: oid, finding: { severity: "high" } })

    assert_equal oid.to_s, out["id"]
    assert_not out.key?("_id")
    assert out.key?("finding")
  end

  test "all AND-combines filters with a case-insensitive search $or" do
    collection = FakeCollection.new([])

    stub_methods(HunterMongo, ensure_indexes_once!: true, collection: collection) do
      Vulnerabilities::MongoSource.all(filters: { "severity" => "high" }, search: "sql", limit: 10)
    end

    assert_equal "high", collection.last_filter["finding.severity"]
    assert_equal(
      [
        { "finding.name" => { "$regex" => "sql", "$options" => "i" } },
        { "target.host" => { "$regex" => "sql", "$options" => "i" } }
      ],
      collection.last_filter["$or"]
    )
  end

  test "build_filter maps allowed keys and drops blanks and unknowns" do
    out = Vulnerabilities::MongoSource.send(
      :build_filter, { "program" => "acme", "status" => "", "nope" => "x" }
    )

    assert_equal({ "metadata.program" => "acme" }, out)
  end

  test "find returns nil for an invalid object id without hitting mongo" do
    assert_nil Vulnerabilities::MongoSource.find("not-an-object-id")
  end

  OID = "507f1f77bcf86cd799439011" # valid 24-hex ObjectId string

  def fake_collection(&update_one)
    Object.new.tap { |o| o.define_singleton_method(:update_one, &update_one) }
  end

  test "update_status $sets status and attribution, returning the refreshed doc" do
    user = users(:one)
    captured = nil
    coll = fake_collection { |_filter, update| captured = update; Struct.new(:matched_count).new(1) }

    result = stub_methods(Vulnerabilities::MongoSource, collection: coll, find: { "id" => OID, "report" => { "status" => "triage" } }) do
      Vulnerabilities::MongoSource.update_status(id: OID, status: "triage", user: user)
    end

    set = captured["$set"]
    assert_equal "triage",      set["report.status"]
    assert_equal user.username, set["report.status_updated_by"]
    assert_kind_of Time,        set["report.status_updated_at"]
    assert_equal({ "id" => OID, "report" => { "status" => "triage" } }, result)
  end

  test "update_status rejects an unknown status without writing" do
    user = users(:one)
    wrote = false
    coll = fake_collection { |*| wrote = true; Struct.new(:matched_count).new(1) }

    stub_methods(Vulnerabilities::MongoSource, collection: coll) do
      assert_raises(ArgumentError) { Vulnerabilities::MongoSource.update_status(id: OID, status: "bogus", user: user) }
    end
    refute wrote
  end

  test "update_status lets a Mongo write error propagate" do
    user = users(:one)
    coll = fake_collection { |*| raise Mongo::Error, "boom" }

    stub_methods(Vulnerabilities::MongoSource, collection: coll) do
      assert_raises(Mongo::Error) { Vulnerabilities::MongoSource.update_status(id: OID, status: "triage", user: user) }
    end
  end
end
