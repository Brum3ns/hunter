require "test_helper"

class Api::V1::TokenScopeTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }

  def auth(raw) = { "Authorization" => "Bearer #{raw}" }

  test "a cves-scoped token reaches the CVE API" do
    _rec, raw = ApiToken.generate(user: @user, name: "llm", scopes: ["cves"])
    stub_methods(Cves::MongoSource, all: [], count: 0) do
      get "/api/v1/cves", headers: auth(raw)
      assert_response :success
    end
  end

  test "a cves-scoped token is forbidden from another module" do
    _rec, raw = ApiToken.generate(user: @user, name: "llm", scopes: ["cves"])
    get "/api/v1/vulnerabilities", headers: auth(raw)
    assert_response :forbidden
    assert_equal "insufficient_scope", JSON.parse(response.body)["error"]
  end

  test "a wildcard token reaches the CVE API" do
    _rec, raw = ApiToken.generate(user: @user, name: "all")
    stub_methods(Cves::MongoSource, all: [], count: 0) do
      get "/api/v1/cves", headers: auth(raw)
      assert_response :success
    end
  end

  test "a browser session is unaffected by scopes" do
    sign_in_as(@user)
    stub_methods(Cves::MongoSource, all: [], count: 0) do
      get "/api/v1/cves"
      assert_response :success
    end
  end
end
