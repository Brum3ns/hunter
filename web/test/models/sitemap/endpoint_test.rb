require "test_helper"

class Sitemap::EndpointTest < ActiveSupport::TestCase
  def digest(url) = Sitemap::Origin.digest(url, "GET")

  test "unmatched scope selects rows with no target" do
    e = Sitemap::Endpoint.create!(origin: "https://ex.com:443", url: "https://ex.com:443/x",
      path: "/x", method: "GET", url_digest: digest("https://ex.com:443/x"),
      crawl_mongo_id: "c1", first_seen_at: Time.current, last_seen_at: Time.current)
    assert_includes Sitemap::Endpoint.unmatched, e
  end

  test "active and tombstoned scopes" do
    now = Time.current
    live = Sitemap::Endpoint.create!(origin: "https://ex.com:443", url: "https://ex.com:443/a",
      path: "/a", method: "GET", url_digest: digest("https://ex.com:443/a"),
      first_seen_at: now, last_seen_at: now)
    dead = Sitemap::Endpoint.create!(origin: "https://ex.com:443", url: "https://ex.com:443/b",
      path: "/b", method: "GET", url_digest: digest("https://ex.com:443/b"),
      first_seen_at: now, last_seen_at: now, removed_at: now)
    assert_includes Sitemap::Endpoint.active, live
    assert_includes Sitemap::Endpoint.tombstoned, dead
    refute_includes Sitemap::Endpoint.active, dead
  end
end
