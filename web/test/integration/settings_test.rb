require "test_helper"

class SettingsTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }

  test "unauthenticated settings redirects to sign in" do
    get settings_path
    assert_response :redirect
  end

  test "settings lists runners" do
    sign_in_as(@user)
    Runner.generate(name: "curl-runner", kinds: %w[curl])
    get settings_path
    assert_response :success
    assert_includes @response.body, "curl-runner"
  end
end
