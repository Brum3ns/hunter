require "test_helper"

class Api::V1::VulnerabilitiesTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }

  Source = Vulnerabilities::MongoSource

  test "returns 401 without a cookie or token" do
    get "/api/v1/vulnerabilities"
    assert_response :unauthorized
    assert_equal "unauthorized", JSON.parse(response.body)["error"]
  end

  test "index works for a cookie-authenticated user" do
    sign_in_as(@user)
    stub_methods(Source, all: [{ "id" => "1", "finding" => {} }], count: 1) do
      get "/api/v1/vulnerabilities"
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal 1, body["count"]
      assert_equal 1, body["vulnerabilities"].length
    end
  end

  test "index authenticates via a bearer token" do
    _record, raw = ApiToken.generate(user: @user, name: "ci")
    stub_methods(Source, all: [], count: 0) do
      get "/api/v1/vulnerabilities", headers: { "Authorization" => "Bearer #{raw}" }
      assert_response :success
    end
  end

  test "index passes filters through and clamps the limit" do
    sign_in_as(@user)
    captured = nil
    capture = ->(filters:, search:, page:, limit:) { captured = { filters: filters, search: search, page: page, limit: limit }; [] }

    stub_methods(Source, all: capture, count: 0) do
      get "/api/v1/vulnerabilities", params: { severity: "high", page: "3", limit: "9999" }
    end

    assert_equal({ "severity" => "high" }, captured[:filters])
    assert_equal 3, captured[:page]
    assert_equal 200, captured[:limit]
  end

  test "index forwards the q param as a search to the source" do
    sign_in_as(@user)
    captured = nil
    capture = ->(filters:, search:, page:, limit:) { captured = search; [] }

    stub_methods(Source, all: capture, count: 0) do
      get "/api/v1/vulnerabilities", params: { q: "sql" }
    end

    assert_equal "sql", captured
  end

  test "show returns the document or 404" do
    sign_in_as(@user)
    stub_methods(Source, find: { "id" => "abc", "finding" => { "name" => "X" } }) do
      get "/api/v1/vulnerabilities/abc"
      assert_response :success
      assert_equal "abc", JSON.parse(response.body)["id"]
    end

    stub_methods(Source, find: nil) do
      get "/api/v1/vulnerabilities/missing"
      assert_response :not_found
    end
  end

  test "create inserts the body and returns 201 with the new id" do
    sign_in_as(@user)
    stub_methods(Source, create: "new-id") do
      post "/api/v1/vulnerabilities", params: { finding: { name: "x" } }, as: :json
      assert_response :created
      assert_equal "new-id", JSON.parse(response.body)["id"]
    end
  end

  test "update returns the updated document or 404" do
    sign_in_as(@user)
    stub_methods(Source, update: { "id" => "abc", "report" => { "status" => "triaged" } }) do
      patch "/api/v1/vulnerabilities/abc", params: { report: { status: "triaged" } }, as: :json
      assert_response :success
      assert_equal "triaged", JSON.parse(response.body).dig("report", "status")
    end

    stub_methods(Source, update: nil) do
      patch "/api/v1/vulnerabilities/missing", params: {}, as: :json
      assert_response :not_found
    end
  end

  test "destroy returns 204 on success and 404 when absent" do
    sign_in_as(@user)
    stub_methods(Source, delete: true) do
      delete "/api/v1/vulnerabilities/abc"
      assert_response :no_content
    end

    stub_methods(Source, delete: false) do
      delete "/api/v1/vulnerabilities/missing"
      assert_response :not_found
    end
  end

  test "maps a Mongo write failure to 502" do
    sign_in_as(@user)
    stub_methods(Source, create: ->(*) { raise Mongo::Error.new("down") }) do
      post "/api/v1/vulnerabilities", params: { finding: {} }, as: :json
      assert_response :bad_gateway
      assert_equal "upstream_unavailable", JSON.parse(response.body)["error"]
    end
  end
end
