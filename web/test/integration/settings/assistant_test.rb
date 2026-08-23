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
    assert_select "input[name='settings[operational_access_enabled]']"
    assert_select "input[name='settings[conversation_management_enabled]']"
    assert_select "select[name='settings[disabled_capability_tools][]'] option", count: 70
    assert_select "select[name='settings[disabled_capability_effects][]'] option"
    assert_select "select[name='settings[disabled_capability_modules][]'] option"
    assert_includes response.body, "including for active turn grants"
    assert_includes response.body, "64 tool calls"
    assert_includes response.body, "administrator-equivalent operational access"
    assert_includes response.body, "rename and reorder"
    assert_includes response.body, "never see secrets"
    assert_includes response.body, "delete records"
    assert_select "section#assistant article[data-assistant-backend]", count: 2
    assert_select "section#assistant article[data-assistant-backend='codex']", text: /OpenAI/
    assert_select "section#assistant article[data-assistant-backend='claude_code']", text: /Anthropic/
    assert_select "section#assistant article[data-assistant-backend='codex'] img[src*='assistant/openai']"
    assert_select "section#assistant article[data-assistant-backend='claude_code'] img[src*='assistant/anthropic']"
    assert_includes response.body, "codex login --device-auth"
    assert_includes response.body, "claude login"
    assert_includes response.body, "Hunter MCP gateway"
    assert_includes response.body, "provider-owned internal utility and discovery tools"
    assert_includes response.body, "no direct Hunter or host access"
    assert_includes response.body, "subscription"
    assert_includes response.body, "API-key provider profiles are retired"
    assert_select "section#assistant form[action='/api/v1/assistant/provider_profiles']", count: 0
    assert_select "section#assistant [name^='provider_profile']", count: 0
    refute_includes response.body, "Reviewed provider profiles"
    refute_includes response.body, "Add reviewed profile"
    refute_includes response.body, "secret_ref"
    refute_includes response.body, "base_url"
    refute_includes response.body, "Authorization"
    refute_includes response.body, "provider_profile_id"
  end

  test "other authenticated users do not receive assistant administration" do
    sign_in_as(users(:two))

    get settings_path

    assert_response :success
    assert_select "section#assistant", count: 0
    refute_includes response.body, "/api/v1/assistant"
  end
end
