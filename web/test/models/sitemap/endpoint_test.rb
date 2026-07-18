require "test_helper"

class Sitemap::EndpointTest < ActiveSupport::TestCase
  test "derive_source from provenance ids" do
    assert_equal "katana",  Sitemap::Endpoint.derive_source("a", nil)
    assert_equal "wayback", Sitemap::Endpoint.derive_source(nil, "b")
    assert_equal "both",    Sitemap::Endpoint.derive_source("a", "b")
    assert_nil              Sitemap::Endpoint.derive_source(nil, nil)
  end

  test "unmatched scope selects rows with no target" do
    e = Sitemap::Endpoint.create!(origin: "https://ex.com:443", url: "https://ex.com:443/x",
      path: "/x", method: "GET", source: "katana", url_digest: Sitemap::Origin.digest("https://ex.com:443/x", "GET"),
      katana_mongo_id: "a", first_seen_at: Time.current, last_seen_at: Time.current)
    assert_includes Sitemap::Endpoint.unmatched, e
  end
end
