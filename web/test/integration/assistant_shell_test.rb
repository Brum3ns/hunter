require "test_helper"

class AssistantShellTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:one)
    @original_admin_username = ENV["ADMIN_USERNAME"]
    ENV["ADMIN_USERNAME"] = @admin.username
  end

  teardown do
    ENV["ADMIN_USERNAME"] = @original_admin_username
  end

  test "assistant shell renders only for the configured session administrator" do
    sign_in_as(@admin)
    get root_path

    assert_response :success
    assert_select "[data-controller='assistant']", count: 1
    assert_select "button[aria-label='Open Hunter assistant'][aria-expanded='false']", count: 1

    sign_out
    sign_in_as(users(:two))
    get root_path
    assert_select "[data-controller='assistant']", count: 0

    sign_out
    get new_session_path
    assert_select "[data-controller='assistant']", count: 0
  end

  test "shell exposes accessible panel controls and safe empty regions" do
    sign_in_as(@admin)
    get root_path

    assert_select "[role='dialog'][aria-modal='true'][aria-labelledby='hunter-assistant-title'][hidden]"
    assert_select "button[aria-label='Close Hunter assistant']"
    assert_select "form[data-action*='assistant#startConversation'] select[data-assistant-target='providerSelect']"
    assert_select "[data-assistant-target='retentionNotice']", text: /retention/i
    assert_select "form[data-action*='assistant#submitMessage'] textarea"
    assert_select "[data-assistant-target='disclosurePreview']"
    assert_select "[data-assistant-target='drafts'][aria-live='polite']"
    assert_select "[data-controller='toaster'].bottom-24"
  end

  test "server-rendered profile data remains escaped and no secret metadata is present" do
    assistant_provider_profiles(:openai).update!(name: "<script>alert(1)</script>")
    sign_in_as(@admin)

    get root_path

    assert_response :success
    assert_select "script", text: "alert(1)", count: 0
    refute_includes response.body, "secret_ref"
    refute_includes response.body, "openai_primary"
  end
end
