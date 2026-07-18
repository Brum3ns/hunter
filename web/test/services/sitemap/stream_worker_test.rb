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

  test "delete of an alive doc tombstones the matching target by alive_mongo_id" do
    t = Sitemap::Applier.upsert_target({ origin: "https://ex.com:443", scheme: "https", host: "ex.com", port: 443, program: nil, alive_mongo_id: "a1" }, now: now)
    worker = Sitemap::StreamWorker.new(Sitemap::MongoSource::ALIVE, source: nil)
    worker.apply_event(event("delete", key: "a1"))
    assert t.reload.removed_at.present?
  end

  test "insert of a wayback doc upserts a wayback endpoint" do
    Sitemap::Applier.upsert_target({ origin: "https://ex.com:443", scheme: "https", host: "ex.com", port: 443, program: nil, alive_mongo_id: "a1" }, now: now)
    worker = Sitemap::StreamWorker.new(Sitemap::MongoSource::WAYBACK, source: "wayback")
    worker.apply_event(event("insert", doc: { "_id" => "w1", "url" => "https://ex.com/a" }))
    ep = Sitemap::Endpoint.active.sole
    assert_equal "wayback", ep.source
    assert_equal "https://ex.com:443/a", ep.url
  end

  test "record_stream_failure clears the persisted resume token only at the threshold" do
    MongoStreamCursor.save_token(Sitemap::MongoSource::KATANA, { "_data" => "stale" })
    worker = Sitemap::StreamWorker.new(Sitemap::MongoSource::KATANA, source: "katana")

    (Sitemap::StreamWorker::MAX_RESUME_FAILURES - 1).times do
      cleared = worker.send(:record_stream_failure)
      assert_equal false, cleared
      assert_equal({ "_data" => "stale" }, MongoStreamCursor.token_for(Sitemap::MongoSource::KATANA))
    end

    cleared = worker.send(:record_stream_failure)
    assert_equal true, cleared
    assert_nil MongoStreamCursor.token_for(Sitemap::MongoSource::KATANA)
  end
end
