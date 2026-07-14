require "test_helper"

class Api::V1::OpenapiTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }

  test "401 without a cookie or token" do
    get "/api/v1/openapi.json"
    assert_response :unauthorized
    assert_equal "unauthorized", JSON.parse(response.body)["error"]
  end

  test "session request gets the full document with every module tag" do
    sign_in_as(@user)
    get "/api/v1/openapi.json"
    assert_response :success
    doc = JSON.parse(response.body)
    assert_equal "3.1.0", doc["openapi"]
    assert doc["paths"].key?("/api/v1/cves"), "cves documented"
    assert doc["paths"].key?("/api/v1/vulnerabilities"), "vulnerabilities documented"
    assert doc["paths"].key?("/api/v1/programs/changes"), "programs documented"
  end

  test "cves-scoped bearer gets only CVE paths" do
    _rec, raw = ApiToken.generate(user: @user, name: "llm", scopes: ["cves"])
    get "/api/v1/openapi.json", headers: { "Authorization" => "Bearer #{raw}" }
    assert_response :success
    doc = JSON.parse(response.body)
    assert doc["paths"].key?("/api/v1/cves")
    refute doc["paths"].key?("/api/v1/vulnerabilities")
    refute doc["paths"].key?("/api/v1/programs/changes")
  end

  test "the .json-less canonical path also resolves" do
    sign_in_as(@user)
    get "/api/v1/openapi"
    assert_response :success
    assert_equal "3.1.0", JSON.parse(response.body)["openapi"]
  end
end
