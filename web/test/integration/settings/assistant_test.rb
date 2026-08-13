require "test_helper"

class Settings::AssistantTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:one)
    @original_admin_username = ENV["ADMIN_USERNAME"]
    ENV["ADMIN_USERNAME"] = @admin.username
  end

  teardown do
    ENV["ADMIN_USERNAME"] = @original_admin_username
  end

  test "configured administrator sees bounded assistant controls" do
    sign_in_as(@admin)

    get settings_path

    assert_response :success
    assert_select "a[href='#assistant']", text: "Assistant"
    assert_select "section#assistant h2", text: "Assistant"
    assert_select "form[action='/api/v1/assistant/settings']"
    assert_select "input[name='settings[transcript_retention_days]'][min='1'][max='30']"
    assert_select "input[name='settings[audit_retention_days]'][min='1'][max='365']"
    assert_select "input[name='settings[control_center_write_enabled]']"
	assert_select "input[name='settings[conversation_management_enabled]']"
	assert_includes response.body, "create and explicitly edit"
	assert_includes response.body, "rename and reorder"
	assert_includes response.body, "never delete or run"
    refute_includes response.body, "secret_ref"
    refute_includes response.body, "base_url"
    refute_includes response.body, "Authorization"
  end

  test "other authenticated users do not receive assistant administration" do
    sign_in_as(users(:two))

    get settings_path

    assert_response :success
    assert_select "section#assistant", count: 0
    refute_includes response.body, "/api/v1/assistant"
  end
end
