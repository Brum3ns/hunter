require "test_helper"

class Api::V1::TargetsScopeTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }

  def auth(raw) = { "Authorization" => "Bearer #{raw}" }

  test "targets index now requires the targets scope for bearer tokens" do
    stub_methods(Targets::MongoSource, all: [], count: 0) do
      _rec, bad = ApiToken.generate(user: @user, name: "llm", scopes: ["cves"])
      get "/api/v1/targets", headers: auth(bad)
      assert_response :forbidden

      _rec, ok = ApiToken.generate(user: @user, name: "llm", scopes: ["targets"])
      get "/api/v1/targets", headers: auth(ok)
      assert_response :success
    end
  end
end
