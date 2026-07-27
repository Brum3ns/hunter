require "test_helper"

class Api::V1::Sitemap::EndpointsTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }

  def auth(raw) = { "Authorization" => "Bearer #{raw}" }

  def endpoint(url)
    Sitemap::Endpoint.create!(origin: "https://example.com", url: url, path: URI(url).path.presence || "/",
      method: "GET", url_digest: Digest::SHA256.digest("GET\0#{url}"),
      first_seen_at: Time.current, last_seen_at: Time.current)
  end

  test "index returns a paginated endpoint envelope for a signed-in user" do
    endpoint("https://example.com/a")
    sign_in_as(@user)
    get "/api/v1/sitemap/endpoints", params: { limit: 10 }
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 1, body["total"]
    assert_equal "https://example.com/a", body["endpoints"].first["url"]
    assert_equal 1, body["page"]
    assert_equal 10, body["limit"]
  end

  test "a bearer token without the sitemap scope is rejected" do
    _rec, raw = ApiToken.generate(user: @user, name: "llm", scopes: ["cves"])
    get "/api/v1/sitemap/endpoints", headers: auth(raw)
    assert_response :forbidden
    assert_equal "insufficient_scope", JSON.parse(response.body)["error"]
  end

  test "a bearer token with the sitemap scope is accepted" do
    endpoint("https://example.com/b")
    _rec, raw = ApiToken.generate(user: @user, name: "llm", scopes: ["sitemap"])
    get "/api/v1/sitemap/endpoints", headers: auth(raw)
    assert_response :success
  end
end
