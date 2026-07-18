require "test_helper"

class Sitemap::ApplierTest < ActiveSupport::TestCase
  def now = Time.current

  def katana_attrs(url: "https://ex.com:443/a")
    { origin: "https://ex.com:443", url: url, path: "/a", method: "GET", source: "katana",
      status_code: 200, content_length: nil, content_type: nil, source_mongo_id: "k1" }
  end

  def wayback_attrs(url: "https://ex.com:443/a")
    { origin: "https://ex.com:443", url: url, path: "/a", method: "GET", source: "wayback",
      status_code: nil, content_length: nil, content_type: nil, source_mongo_id: "w1" }
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
    e = Sitemap::Applier.upsert_endpoint(katana_attrs, now: now)
    assert_equal "https://ex.com:443", e.target.origin
    assert_equal "katana", e.source
  end

  test "unmatched endpoint lands in the bucket then attaches when target appears" do
    e = Sitemap::Applier.upsert_endpoint(katana_attrs, now: now)
    assert_nil e.target_id
    t = Sitemap::Applier.upsert_target(target_attrs, now: now)
    Sitemap::Applier.attach_orphans_for(t, now: now)
    assert_equal t.id, e.reload.target_id
  end

  test "katana then wayback for same url converge to source=both" do
    Sitemap::Applier.upsert_target(target_attrs, now: now)
    Sitemap::Applier.upsert_endpoint(katana_attrs, now: now)
    e = Sitemap::Applier.upsert_endpoint(wayback_attrs, now: now)
    assert_equal 1, Sitemap::Endpoint.count
    assert_equal "both", e.source
  end

  test "tombstone_endpoint_by_source only tombstones when no source remains" do
    Sitemap::Applier.upsert_target(target_attrs, now: now)
    Sitemap::Applier.upsert_endpoint(katana_attrs, now: now)
    e = Sitemap::Applier.upsert_endpoint(wayback_attrs, now: now)
    Sitemap::Applier.tombstone_endpoint_by_source("katana", "k1", now: now)
    assert_nil e.reload.removed_at
    assert_equal "wayback", e.source
    Sitemap::Applier.tombstone_endpoint_by_source("wayback", "w1", now: now)
    assert e.reload.removed_at.present?
  end
end
