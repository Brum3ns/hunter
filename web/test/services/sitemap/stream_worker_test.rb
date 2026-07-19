require "test_helper"

class Sitemap::StreamWorkerTest < ActiveSupport::TestCase
  def now = Time.current

  def event(op, doc: nil, key: nil, token: { "_data" => "t1" })
    ev = { "operationType" => op, "_id" => token }
    ev["fullDocument"] = doc if doc
    ev["documentKey"] = { "_id" => key } if key
    ev
  end

  def target!
    Sitemap::Applier.upsert_target({ origin: "https://ex.com:443", scheme: "https", host: "ex.com",
                                     port: 443, program: nil, alive_mongo_id: "a1" }, now: now)
  end

  test "insert of a crawl doc upserts an endpoint and saves the token" do
    target!
    worker = Sitemap::StreamWorker.new(Sitemap::MongoSource::CRAWL, source: "crawl")
    worker.apply_event(event("insert", doc: { "_id" => "c1", "request" => { "url" => "https://ex.com/a", "method" => "GET" }, "response" => {} }))
    ep = Sitemap::Endpoint.active.sole
    assert_equal "https://ex.com:443/a", ep.url
    assert_equal "c1", ep.crawl_mongo_id
    assert_equal({ "_data" => "t1" }, MongoStreamCursor.token_for(Sitemap::MongoSource::CRAWL))
  end

  test "delete of a crawl doc tombstones the endpoint carrying its id" do
    target!
    Sitemap::Applier.upsert_endpoint({ origin: "https://ex.com:443", url: "https://ex.com:443/a", path: "/a", method: "GET", crawl_mongo_id: "c1" }, now: now)
    worker = Sitemap::StreamWorker.new(Sitemap::MongoSource::CRAWL, source: "crawl")
    worker.apply_event(event("delete", key: "c1"))
    assert Sitemap::Endpoint.sole.removed_at.present?
  end

  test "insert of an alive doc upserts a target and attaches orphans" do
    Sitemap::Applier.upsert_endpoint({ origin: "https://ex.com:443", url: "https://ex.com:443/a", path: "/a", method: "GET", crawl_mongo_id: "c1" }, now: now)
    worker = Sitemap::StreamWorker.new(Sitemap::MongoSource::ALIVE, source: nil)
    worker.apply_event(event("insert", doc: { "_id" => "a1", "target" => { "scheme" => "https", "host" => "ex.com", "port" => 443 }, "metadata" => {} }))
    assert Sitemap::Endpoint.sole.target_id.present?
  end

  test "delete of an alive doc tombstones the matching target by alive_mongo_id" do
    t = target!
    worker = Sitemap::StreamWorker.new(Sitemap::MongoSource::ALIVE, source: nil)
    worker.apply_event(event("delete", key: "a1"))
    assert t.reload.removed_at.present?
  end

  test "record_stream_failure clears the persisted resume token only at the threshold" do
    MongoStreamCursor.save_token(Sitemap::MongoSource::CRAWL, { "_data" => "stale" })
    worker = Sitemap::StreamWorker.new(Sitemap::MongoSource::CRAWL, source: "crawl")

    (Sitemap::StreamWorker::MAX_RESUME_FAILURES - 1).times do
      cleared = worker.send(:record_stream_failure)
      assert_equal false, cleared
      assert_equal({ "_data" => "stale" }, MongoStreamCursor.token_for(Sitemap::MongoSource::CRAWL))
    end

    cleared = worker.send(:record_stream_failure)
    assert_equal true, cleared
    assert_nil MongoStreamCursor.token_for(Sitemap::MongoSource::CRAWL)
  end
end
