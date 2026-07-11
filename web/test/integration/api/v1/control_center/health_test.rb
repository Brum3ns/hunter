require "test_helper"

class Api::V1::ControlCenter::HealthTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }

  test "requires auth" do
    get "/api/v1/control_center/health"
    assert_response :unauthorized
  end

  test "reports rabbitmq and mongo status" do
    sign_in_as(@user)
    health = { rabbitmq: { ok: true, detail: "" }, mongo: { ok: false, detail: "down" } }
    stub_methods(ControlCenter::Standalone, health: health) do
      get "/api/v1/control_center/health"
    end
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal true, body["rabbitmq"]["ok"]
    assert_equal false, body["mongo"]["ok"]
  end
end
