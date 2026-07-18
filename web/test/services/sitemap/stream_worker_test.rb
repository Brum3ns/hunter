require "test_helper"

class Sitemap::StreamWorkerTest < ActiveSupport::TestCase
  def now = Time.current

  def event(op, doc: nil, key: nil, token: { "_data" => "t1" })
    ev = { "operationType" => op, "_id" => token }
    ev["fullDocument"] = doc if doc
    ev["documentKey"] = { "_id" => key } if key
    ev
  end

  test "insert of a katana doc upserts an endpoint and saves the token" do
    Sitemap::Applier.upsert_target({ origin: "https://ex.com:443", scheme: "https", host: "ex.com", port: 443, program: nil, alive_mongo_id: "a1" }, now: now)
    worker = Sitemap::StreamWorker.new(Sitemap::MongoSource::KATANA, source: "katana")
    worker.apply_event(event("insert", doc: { "_id" => "k1", "request" => { "endpoint" => "https://ex.com/a", "method" => "GET" }, "response" => {} }))
    assert_equal 1, Sitemap::Endpoint.active.count
    assert_equal({ "_data" => "t1" }, MongoStreamCursor.token_for(Sitemap::MongoSource::KATANA))
  end

  test "delete of a katana doc tombstones via its source id" do
    Sitemap::Applier.upsert_target({ origin: "https://ex.com:443", scheme: "https", host: "ex.com", port: 443, program: nil, alive_mongo_id: "a1" }, now: now)
    Sitemap::Applier.upsert_endpoint({ origin: "https://ex.com:443", url: "https://ex.com:443/a", path: "/a", method: "GET", source: "katana", source_mongo_id: "k1" }, now: now)
    worker = Sitemap::StreamWorker.new(Sitemap::MongoSource::KATANA, source: "katana")
    worker.apply_event(event("delete", key: "k1"))
    assert Sitemap::Endpoint.sole.removed_at.present?
  end

  test "insert of an alive doc upserts a target and attaches orphans" do
    Sitemap::Applier.upsert_endpoint({ origin: "https://ex.com:443", url: "https://ex.com:443/a", path: "/a", method: "GET", source: "katana", source_mongo_id: "k1" }, now: now)
    worker = Sitemap::StreamWorker.new(Sitemap::MongoSource::ALIVE, source: nil)
    worker.apply_event(event("insert", doc: { "_id" => "a1", "target" => { "scheme" => "https", "host" => "ex.com", "port" => 443 }, "metadata" => {} }))
    assert Sitemap::Endpoint.sole.target_id.present?
  end
end
