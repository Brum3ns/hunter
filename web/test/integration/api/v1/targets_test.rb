require "test_helper"

class Api::V1::TargetsTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }

  Source = Targets::MongoSource

  test "returns 401 without a cookie or token" do
    get "/api/v1/targets"
    assert_response :unauthorized
    assert_equal "unauthorized", JSON.parse(response.body)["error"]
  end

  test "index returns a paginated envelope for an authenticated user" do
    sign_in_as(@user)
    stub_methods(Source, all: [{ "id" => "1", "target" => { "host" => "a" } }], count: 1) do
      get "/api/v1/targets"
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal 1, body["count"]
      assert_equal 1, body["targets"].length
      assert_equal "a", body["targets"].first["target"]["host"]
    end
  end

  test "index passes search, sort and filters through and clamps the limit" do
    sign_in_as(@user)
    captured = nil
    capture = ->(filters:, search:, expression:, sort:, dir:, page:, limit:) {
      captured = { filters:, search:, sort:, dir:, page:, limit: }; []
    }
    stub_methods(Source, all: capture, count: 0) do
      get "/api/v1/targets", params: { q: "nginx", program: "acme", sort: "host", dir: "asc", page: "2", limit: "9999" }
    end
    assert_equal({ "program" => "acme" }, captured[:filters])
    assert_equal "nginx", captured[:search]
    assert_equal "host", captured[:sort]
    assert_equal "asc", captured[:dir]
    assert_equal 2, captured[:page]
    assert_equal 200, captured[:limit]
  end

  test "show returns the document or 404" do
    sign_in_as(@user)
    stub_methods(Source, find: { "id" => "abc", "target" => { "host" => "a" } }) do
      get "/api/v1/targets/abc"
      assert_response :success
      assert_equal "abc", JSON.parse(response.body)["id"]
    end
    stub_methods(Source, find: nil) do
      get "/api/v1/targets/missing"
      assert_response :not_found
    end
  end
end
