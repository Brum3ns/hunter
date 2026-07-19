require "test_helper"

class Sitemap::EndpointFilterTest < ActiveSupport::TestCase
  def target
    @target ||= begin
      now = Time.current
      Sitemap::Target.create!(origin: "https://ex.com:443", scheme: "https", host: "ex.com", port: 443,
                              first_seen_at: now, last_seen_at: now)
    end
  end

  def ep!(path:, method: "GET", status: 200, url: nil, content_type: nil)
    now = Time.current
    url ||= "https://ex.com:443#{path}"
    Sitemap::Endpoint.create!(target_id: target.id, origin: target.origin, url: url, path: path,
      method: method, status_code: status, content_type: content_type,
      url_digest: Sitemap::Origin.digest(url, method), first_seen_at: now, last_seen_at: now)
  end

  def apply(params) = Sitemap::EndpointFilter.apply(Sitemap::Endpoint.active, params).to_a

  test "blank params return the scope unfiltered" do
    a = ep!(path: "/a")
    assert_includes apply({}), a
  end

  test "methods filter (upcased)" do
    g = ep!(path: "/g", method: "GET"); p = ep!(path: "/p", method: "POST")
    result = apply(methods: ["post"])
    assert_includes result, p
    assert_not_includes result, g
  end

  test "status family filter excludes null and out-of-range" do
    ok = ep!(path: "/ok", status: 200); notf = ep!(path: "/nf", status: 404); nul = ep!(path: "/n", status: nil)
    result = apply(status: ["2"])
    assert_includes result, ok
    assert_not_includes result, notf
    assert_not_includes result, nul
  end

  test "path substring filter" do
    admin = ep!(path: "/admin/x"); other = ep!(path: "/public")
    result = apply(path: "admin")
    assert_includes result, admin
    assert_not_includes result, other
  end

  test "has_query filter matches urls with a query string" do
    q = ep!(path: "/s", url: "https://ex.com:443/s?a=1"); plain = ep!(path: "/t")
    result = apply(has_query: "1")
    assert_includes result, q
    assert_not_includes result, plain
  end

  test "content_type filter" do
    js = ep!(path: "/a.js", content_type: "application/javascript"); html = ep!(path: "/b", content_type: "text/html")
    result = apply(content_type: "javascript")
    assert_includes result, js
    assert_not_includes result, html
  end

  test "filters compose" do
    hit = ep!(path: "/api/x", method: "POST", status: 200)
    miss = ep!(path: "/api/y", method: "GET", status: 200)
    result = apply(methods: ["POST"], status: ["2"], path: "api")
    assert_equal [hit], result
  end
end
