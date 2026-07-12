require "test_helper"

class Cves::SyncTest < ActiveSupport::TestCase
  # Stub client: ecosystems + a records map keyed by ecosystem.
  class FakeClient
    def initialize(records_by_eco) = @records = records_by_eco
    def ecosystems = @records.keys
    def each_record(eco)
      raise "boom #{eco}" if @records[eco] == :error
      @records[eco].each { |r| yield r }
    end
  end

  def cve_record(cve) = { "id" => "GHSA-#{cve}", "aliases" => [cve], "affected" => [], "references" => [] }

  test "normalizes, skips non-CVE records, and upserts the rest" do
    client = FakeClient.new(
      "npm" => [cve_record("CVE-1"), { "id" => "GHSA-only", "aliases" => ["GHSA-only"] }],
      "PyPI" => [cve_record("CVE-2")]
    )
    upserted = []
    stub_methods(Cves::MongoSource, upsert: ->(doc) { upserted << doc["id"]; doc["id"] }) do
      stats = Cves::Sync.new(client: client).run
      assert_equal %w[CVE-1 CVE-2], upserted.sort
      assert_equal 2, stats[:upserted]
      assert_equal 1, stats[:skipped]
      assert_equal 2, stats[:ecosystems]
      assert_equal 0, stats[:failed_ecosystems]
    end
  end

  test "a failing ecosystem is isolated and the run continues" do
    client = FakeClient.new("npm" => :error, "PyPI" => [cve_record("CVE-2")])
    upserted = []
    stub_methods(Cves::MongoSource, upsert: ->(doc) { upserted << doc["id"]; doc["id"] }) do
      stats = Cves::Sync.new(client: client).run
      assert_equal ["CVE-2"], upserted
      assert_equal 1, stats[:failed_ecosystems]
      assert_equal 1, stats[:upserted]
    end
  end

  test "run accepts an explicit ecosystem list" do
    client = FakeClient.new("npm" => [cve_record("CVE-1")], "PyPI" => [cve_record("CVE-2")])
    upserted = []
    stub_methods(Cves::MongoSource, upsert: ->(doc) { upserted << doc["id"]; doc["id"] }) do
      Cves::Sync.new(client: client).run(ecosystems: ["PyPI"])
      assert_equal ["CVE-2"], upserted
    end
  end
end
