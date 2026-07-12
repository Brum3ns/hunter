require "test_helper"

class Api::V1::ControlCenter::StatsTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }

  test "requires auth" do
    get "/api/v1/control_center/stats"
    assert_response :unauthorized
  end

  test "returns the dashboard shape" do
    sign_in_as(@user)
    ControlCenter::Job.create!(template_name: "a", status: "succeeded", queue_name: "test", target_count: 2)
    get "/api/v1/control_center/stats"
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 1, body["totals"]["jobs"]
    assert body.key?("by_status")
    assert body.key?("top_templates")
    assert body.key?("daily")
  end
end
