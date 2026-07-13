require "test_helper"

class Api::V1::CvesTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }

  Source = Cves::MongoSource

  test "returns 401 without a cookie or token" do
    get "/api/v1/cves"
    assert_response :unauthorized
    assert_equal "unauthorized", JSON.parse(response.body)["error"]
  end

  test "index returns a paginated envelope" do
    sign_in_as(@user)
    stub_methods(Source, all: [{ "id" => "CVE-1", "summary" => "x" }], count: 1) do
      get "/api/v1/cves"
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal 1, body["count"]
      assert_equal "CVE-1", body["cves"].first["id"]
    end
  end

  test "index passes filters and search through and clamps limit" do
    sign_in_as(@user)
    captured = nil
    capture = ->(filters:, search:, page:, limit:) { captured = { filters:, search:, page:, limit: }; [] }
    stub_methods(Source, all: capture, count: 0) do
      get "/api/v1/cves", params: {
        q: "xss", ecosystem: "npm", package: "foo", has_fix: "true",
        published_after: "2026-01-01", modified_after: "2026-02-01",
        page: "2", limit: "9999"
      }
    end
    assert_equal "xss", captured[:search]
    assert_equal "npm", captured[:filters]["ecosystem"]
    assert_equal "foo", captured[:filters]["package"]
    assert_equal "true", captured[:filters]["has_fix"]
    assert_equal "2026-01-01", captured[:filters]["published_after"]
    assert_equal "2026-02-01", captured[:filters]["modified_after"]
    assert_equal 2, captured[:page]
    assert_equal 200, captured[:limit]
  end

  test "show returns the CVE or 404" do
    sign_in_as(@user)
    stub_methods(Source, find: { "id" => "CVE-2024-1234", "summary" => "x" }) do
      get "/api/v1/cves/CVE-2024-1234"
      assert_response :success
      assert_equal "CVE-2024-1234", JSON.parse(response.body)["id"]
    end
    stub_methods(Source, find: nil) do
      get "/api/v1/cves/CVE-0000-0000"
      assert_response :not_found
    end
  end

  test "new feed parses since, returns records and next_since/next_since_id cursors" do
    sign_in_as(@user)
    t1 = "2026-07-10T00:00:00Z"
    t2 = "2026-07-11T00:00:00Z"
    captured = nil
    capture = ->(since:, since_id:, limit:, filters:, search:) {
      captured = { since:, since_id:, limit: }
      [{ "id" => "CVE-A", "first_seen_at" => t1 }, { "id" => "CVE-B", "first_seen_at" => t2 }]
    }
    stub_methods(Source, new_since: capture) do
      get "/api/v1/cves/new", params: { since: "2026-07-09T00:00:00Z", limit: "10" }
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal %w[CVE-A CVE-B], body["cves"].map { |c| c["id"] }
      assert_equal t2, body["next_since"]
      assert_equal "CVE-B", body["next_since_id"]
    end
    assert_equal Time.iso8601("2026-07-09T00:00:00Z"), captured[:since]
    assert_equal 10, captured[:limit]
  end

  test "new feed tolerates a missing/blank since" do
    sign_in_as(@user)
    captured = nil
    capture = ->(since:, since_id:, limit:, filters:, search:) { captured = { since:, since_id:, limit: }; [] }
    stub_methods(Source, new_since: capture) do
      get "/api/v1/cves/new"
      assert_response :success
      body = JSON.parse(response.body)
      assert_nil body["next_since"]
      assert_nil body["next_since_id"]
    end
    assert_nil captured[:since]
    assert_nil captured[:since_id]
  end

  test "new feed passes since and since_id through to new_since" do
    sign_in_as(@user)
    captured = nil
    capture = ->(since:, since_id:, limit:, filters:, search:) { captured = { since:, since_id:, limit: }; [] }
    stub_methods(Source, new_since: capture) do
      get "/api/v1/cves/new", params: { since: "2026-07-09T00:00:00Z", since_id: "CVE-A", limit: "5" }
      assert_response :success
    end
    assert_equal Time.iso8601("2026-07-09T00:00:00Z"), captured[:since]
    assert_equal "CVE-A", captured[:since_id]
    assert_equal 5, captured[:limit]
  end

  test "applies the token saved filter with no params" do
    _rec, raw = ApiToken.generate(user: @user, name: "llm", scopes: ["cves"])
    @user.api_tokens.find_by(name: "llm").update!(cve_filter: { "ecosystems" => ["npm"], "min_severity" => "high" })
    captured = nil
    capture = ->(filters:, search:, page:, limit:) { captured = filters; [] }
    stub_methods(Source, all: capture, count: 0) do
      get "/api/v1/cves", headers: { "Authorization" => "Bearer #{raw}" }
    end
    assert_equal ["npm"], captured["ecosystem"]
    assert_equal "high", captured["min_severity"]
  end

  test "a request param overrides one saved field while others remain" do
    _rec, raw = ApiToken.generate(user: @user, name: "llm", scopes: ["cves"])
    @user.api_tokens.find_by(name: "llm").update!(cve_filter: { "ecosystems" => ["npm"], "min_severity" => "high" })
    captured = nil
    capture = ->(filters:, search:, page:, limit:) { captured = filters; [] }
    stub_methods(Source, all: capture, count: 0) do
      get "/api/v1/cves", params: { ecosystem: "PyPI" }, headers: { "Authorization" => "Bearer #{raw}" }
    end
    assert_equal "PyPI", captured["ecosystem"]
    assert_equal "high", captured["min_severity"]
  end

  test "fields=core returns the compact serialization" do
    sign_in_as(@user)
    doc = { "id" => "CVE-1", "summary" => "x", "details" => "long", "severity_level" => "high",
            "chain" => { "fix_commits" => [] } }
    stub_methods(Source, all: [doc], count: 1) do
      get "/api/v1/cves", params: { fields: "core" }
      body = JSON.parse(response.body)
      assert_equal "high", body["cves"].first["severity_level"]
      assert_not body["cves"].first.key?("details")
    end
  end

  test "config echoes the token saved filter" do
    _rec, raw = ApiToken.generate(user: @user, name: "llm", scopes: ["cves"])
    @user.api_tokens.find_by(name: "llm").update!(cve_filter: { "ecosystems" => ["npm"] })
    get "/api/v1/cves/config", headers: { "Authorization" => "Bearer #{raw}" }
    assert_response :success
    assert_equal({ "ecosystems" => ["npm"] }, JSON.parse(response.body)["cve_filter"])
  end
end
