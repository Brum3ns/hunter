require "test_helper"

class Sitemap::EndpointsTest < ActionDispatch::IntegrationTest
  setup { sign_in_as(User.take) }

  def endpoint!(path: "/about", status: 200, removed_at: nil)
    now = Time.current
    t = Sitemap::Target.create!(origin: "https://ex.com:443", scheme: "https", host: "ex.com", port: 443,
                                first_seen_at: now, last_seen_at: now)
    Sitemap::Endpoint.create!(target_id: t.id, origin: t.origin, url: "#{t.origin}#{path}", path: path,
      method: "GET", status_code: status, url_digest: Sitemap::Origin.digest("#{t.origin}#{path}", "GET"),
      first_seen_at: now, last_seen_at: now, removed_at: removed_at)
  end

  test "shows method, status, url and last-seen in the detail frame" do
    e = endpoint!(path: "/about", status: 200)
    get targets_sitemap_endpoint_path(e.id)
    assert_response :success
    assert_select "turbo-frame#sitemap_detail"
    assert_match "GET", @response.body
    assert_match "200", @response.body
    assert_match "https://ex.com:443/about", @response.body
  end

  test "missing endpoint is 404" do
    get targets_sitemap_endpoint_path(id: 999_999)
    assert_response :not_found
  end

  test "tombstoned endpoint is 404" do
    e = endpoint!(removed_at: Time.current)
    get targets_sitemap_endpoint_path(e.id)
    assert_response :not_found
  end
end
