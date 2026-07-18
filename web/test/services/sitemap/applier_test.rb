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

  test "a concurrent unique-constraint race on endpoint insert is retried and updates the existing row" do
    Sitemap::Applier.upsert_target(target_attrs, now: now)
    target = Sitemap::Target.active.find_by(origin: target_attrs[:origin])
    digest = Sitemap::Origin.digest(katana_attrs[:url], katana_attrs[:method])

    # Simulate a row that was inserted by a concurrent writer (e.g. the stream
    # worker) after our lookup ran but before our insert landed.
    existing = Sitemap::Endpoint.create!(
      target_id: target.id, origin: katana_attrs[:origin], url: katana_attrs[:url],
      path: katana_attrs[:path], method: katana_attrs[:method], url_digest: digest,
      source: "wayback", wayback_mongo_id: "w-existing", first_seen_at: now, last_seen_at: now
    )

    original_find_endpoint = Sitemap::Applier.method(:find_endpoint)
    calls = 0
    stub_methods(Sitemap::Applier, find_endpoint: lambda { |t, origin, dig|
      calls += 1
      calls == 1 ? nil : original_find_endpoint.call(t, origin, dig)
    }) do
      result = Sitemap::Applier.upsert_endpoint(katana_attrs, now: now)
      assert_equal existing.id, result.id
      assert_equal "both", result.source
      assert_equal "k1", result.katana_mongo_id
      assert_equal 200, result.status_code
    end

    assert_equal 1, Sitemap::Endpoint.where(target_id: target.id, url_digest: digest).count
  end

  test "re-applying with a blank source_mongo_id preserves the last-known source instead of nulling it (M1 guard)" do
    Sitemap::Applier.upsert_target(target_attrs, now: now)
    e = Sitemap::Applier.upsert_endpoint(katana_attrs, now: now)
    assert_equal "katana", e.source

    # A malformed re-sync clears the katana id without supplying a wayback
    # one; derive_source(nil, nil) is nil. Without the guard this would
    # overwrite `source` with nil and violate the NOT NULL constraint.
    e2 = Sitemap::Applier.upsert_endpoint(katana_attrs.merge(source_mongo_id: nil), now: now)
    assert_equal e.id, e2.id
    assert_equal "katana", e2.source
  end
end
