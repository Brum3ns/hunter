require "test_helper"

class Sitemap::ApplierTest < ActiveSupport::TestCase
  def now = Time.current

  def crawl_attrs(url: "https://ex.com:443/a", mongo_id: "c1", status_code: 200)
    { origin: "https://ex.com:443", url: url, path: "/a", method: "GET",
      status_code: status_code, content_length: nil, content_type: nil, crawl_mongo_id: mongo_id }
  end

  def target_attrs
    { origin: "https://ex.com:443", scheme: "https", host: "ex.com", port: 443,
      program: "acme", alive_mongo_id: "a1" }
  end

  test "upsert_target inserts then updates by origin, un-tombstoning" do
    t = Sitemap::Applier.upsert_target(target_attrs, now: now)
    t.tombstone!(now)
    t2 = Sitemap::Applier.upsert_target(target_attrs.merge(program: "beta"), now: now)
    assert_equal t.id, t2.id
    assert_nil t2.removed_at
    assert_equal "beta", t2.program
  end

  test "upsert_endpoint matches an active target" do
    Sitemap::Applier.upsert_target(target_attrs, now: now)
    e = Sitemap::Applier.upsert_endpoint(crawl_attrs, now: now)
    assert_equal "https://ex.com:443", e.target.origin
    assert_equal "c1", e.crawl_mongo_id
    assert_equal 200, e.status_code
  end

  test "unmatched endpoint lands in the bucket then attaches when target appears" do
    e = Sitemap::Applier.upsert_endpoint(crawl_attrs, now: now)
    assert_nil e.target_id
    t = Sitemap::Applier.upsert_target(target_attrs, now: now)
    Sitemap::Applier.attach_orphans_for(t, now: now)
    assert_equal t.id, e.reload.target_id
  end

  test "re-crawling the same url upserts a single row and refreshes its fields" do
    Sitemap::Applier.upsert_target(target_attrs, now: now)
    Sitemap::Applier.upsert_endpoint(crawl_attrs(status_code: 200), now: now)
    e = Sitemap::Applier.upsert_endpoint(crawl_attrs(mongo_id: "c2", status_code: 404), now: now)
    assert_equal 1, Sitemap::Endpoint.count
    assert_equal 404, e.status_code
    assert_equal "c2", e.crawl_mongo_id
  end

  test "tombstone_endpoint_by_mongo_id tombstones the row carrying that id" do
    Sitemap::Applier.upsert_target(target_attrs, now: now)
    e = Sitemap::Applier.upsert_endpoint(crawl_attrs(mongo_id: "c1"), now: now)
    Sitemap::Applier.tombstone_endpoint_by_mongo_id("c1", now: now)
    assert e.reload.removed_at.present?
  end

  test "a concurrent unique-constraint race on endpoint insert is retried and updates the existing row" do
    Sitemap::Applier.upsert_target(target_attrs, now: now)
    target = Sitemap::Target.active.find_by(origin: target_attrs[:origin])
    digest = Sitemap::Origin.digest(crawl_attrs[:url], crawl_attrs[:method])

    # Simulate a row inserted by a concurrent writer (e.g. the stream worker)
    # after our lookup ran but before our insert landed.
    existing = Sitemap::Endpoint.create!(
      target_id: target.id, origin: crawl_attrs[:origin], url: crawl_attrs[:url],
      path: crawl_attrs[:path], method: crawl_attrs[:method], url_digest: digest,
      crawl_mongo_id: "c-existing", first_seen_at: now, last_seen_at: now
    )

    original_find_endpoint = Sitemap::Applier.method(:find_endpoint)
    calls = 0
    stub_methods(Sitemap::Applier, find_endpoint: lambda { |t, origin, dig|
      calls += 1
      calls == 1 ? nil : original_find_endpoint.call(t, origin, dig)
    }) do
      result = Sitemap::Applier.upsert_endpoint(crawl_attrs, now: now)
      assert_equal existing.id, result.id
      assert_equal "c1", result.crawl_mongo_id
      assert_equal 200, result.status_code
    end

    assert_equal 1, Sitemap::Endpoint.where(target_id: target.id, url_digest: digest).count
  end
end
