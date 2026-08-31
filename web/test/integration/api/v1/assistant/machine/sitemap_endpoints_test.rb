require "test_helper"

class Api::V1::Assistant::Machine::SitemapEndpointsTest < ActionDispatch::IntegrationTest
  setup do
    @original_config_enabled = Assistant::Config.method(:enabled?)
    @original_admin_username = ENV["ADMIN_USERNAME"]
    ENV["ADMIN_USERNAME"] = users(:one).username
    Assistant::Config.define_singleton_method(:enabled?) { |*, **| true }
    Assistant::Setting.instance.enable!
    _identity, @service_token = Assistant::ServiceIdentity.generate!(
      name: "sitemap-#{SecureRandom.hex(4)}", role: "mcp_reader"
    )
  end

  teardown do
    Assistant::Config.define_singleton_method(:enabled?, @original_config_enabled)
    ENV["ADMIN_USERNAME"] = @original_admin_username
  end

  test "list_endpoints returns a bounded projection and count" do
    target = sitemap_target
    endpoint(target, url: "https://example.com/a?x=1", path: "/a", status_code: 200)

    get "/api/v1/assistant/machine/sitemap/endpoints", headers: headers

    assert_response :success
    body = response.parsed_body
    assert_equal 1, body["count"]
    item = body["items"].first
    assert_equal %w[id url path method status_code], item.keys
    assert_equal "https://example.com/a?x=1", item["url"]
    assert_equal "GET", item["method"]
  end

  test "list_endpoints is refused when its live capability is disabled" do
    Assistant::Setting.instance.update!(disabled_capability_tools: [ "list_endpoints" ])

    get "/api/v1/assistant/machine/sitemap/endpoints", headers: headers

    assert_response :forbidden
    assert_equal "capability_disabled", response.parsed_body["error"]
  end

  test "list_endpoints narrows by the status filter, accepting a comma-joined string" do
    target = sitemap_target
    endpoint(target, url: "https://example.com/ok", path: "/ok", status_code: 200)
    endpoint(target, url: "https://example.com/missing", path: "/missing", status_code: 404)

    get "/api/v1/assistant/machine/sitemap/endpoints", params: { status: "4" }, headers: headers

    assert_response :success
    body = response.parsed_body
    assert_equal 1, body["count"]
    assert_equal "/missing", body["items"].first["path"]
  end

  test "list_endpoints narrows by the methods filter, accepting a comma-joined string" do
    target = sitemap_target
    endpoint(target, url: "https://example.com/get", path: "/get", method: "GET")
    endpoint(target, url: "https://example.com/post", path: "/post", method: "POST")

    get "/api/v1/assistant/machine/sitemap/endpoints", params: { methods: "POST,PUT" }, headers: headers

    assert_response :success
    body = response.parsed_body
    assert_equal 1, body["count"]
    assert_equal "/post", body["items"].first["path"]
  end

  test "list_endpoints narrows by the q free-text/dork filter via SearchParser" do
    target = sitemap_target
    endpoint(target, url: "https://example.com/admin/login", path: "/admin/login", status_code: 200)
    endpoint(target, url: "https://example.com/public/home", path: "/public/home", status_code: 200)

    get "/api/v1/assistant/machine/sitemap/endpoints", params: { q: "path:admin" }, headers: headers

    assert_response :success
    body = response.parsed_body
    assert_equal 1, body["count"]
    assert_equal "/admin/login", body["items"].first["path"]
  end

  test "get_endpoint returns the full projection including target-derived fields" do
    target = sitemap_target(program: "acme", host: "example.com", scheme: "https", port: 443)
    record = endpoint(
      target, url: "https://example.com/a?x=1", path: "/a", status_code: 200,
      content_type: "text/html", content_length: 512
    )

    get "/api/v1/assistant/machine/sitemap/endpoints/#{record.id}", headers: headers

    assert_response :success
    result = response.parsed_body["endpoint"]
    expected_keys = %w[
      id url path method status_code origin content_type content_length
      first_seen_at last_seen_at program host scheme port
    ]
    assert_equal expected_keys, result.keys
    assert_equal "acme", result["program"]
    assert_equal "example.com", result["host"]
    assert_equal "https", result["scheme"]
    assert_equal 443, result["port"]
    assert_equal "text/html", result["content_type"]
  end

  test "get_endpoint releases the reservation on a miss" do
    get "/api/v1/assistant/machine/sitemap/endpoints/999999999", headers: headers

    assert_response :not_found
  end

  private

  def sitemap_target(program: "acme", host: "example.com", scheme: "https", port: 443)
    Sitemap::Target.create!(
      origin: "https://example.com", host: host, scheme: scheme, port: port, program: program,
      first_seen_at: Time.current, last_seen_at: Time.current
    )
  end

  def endpoint(target, url:, path:, method: "GET", status_code: 200, content_type: nil, content_length: nil)
    Sitemap::Endpoint.create!(
      target: target, origin: "https://example.com", url: url, path: path, method: method,
      status_code: status_code, content_type: content_type, content_length: content_length,
      url_digest: Digest::SHA256.digest("#{method}\0#{url}"),
      first_seen_at: Time.current, last_seen_at: Time.current
    )
  end

  def headers(*)
    { "Authorization" => "Bearer #{@service_token}" }
  end
end
