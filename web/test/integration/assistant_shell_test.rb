require "test_helper"
require "json"

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
    assert_select "#hunter-assistant-panel.assistant-panel[data-assistant-target='panel']"
    assert_select "button[data-assistant-target='resizeHandle'][aria-label='Resize Hunter assistant'][data-action*='pointerdown->assistant#startResize'][data-action*='keydown->assistant#resizeWithKeyboard']"
    assert_select "button[data-assistant-target='resizeHandle'][aria-keyshortcuts='ArrowLeft ArrowRight ArrowUp ArrowDown'][aria-describedby='hunter-assistant-resize-help']"
    assert_select "#hunter-assistant-resize-status[data-assistant-target='resizeStatus'][role='status'][aria-live='polite']"
    assert_select "[data-assistant-resize-label]", text: /Drag to resize/i
    assert_select "button[aria-label='Close Hunter assistant']"
    assert_select "details[data-assistant-target='capabilityDisclosure'] > summary", text: /Data access & actions/i
    assert_select "button[data-assistant-target='providerButton'][data-action='assistant#startConversation'][data-backend]", count: 2
    assert_select "button[data-assistant-target='providerButton'][data-backend='codex'][aria-label*='OpenAI'][title]"
    assert_select "button[data-assistant-target='providerButton'][data-backend='claude_code'][aria-label*='Anthropic'][title]"
    assert_select "button[data-backend='codex'] img[src*='assistant/openai']"
    assert_select "button[data-backend='claude_code'] img[src*='assistant/anthropic']"
    assert_select "[data-assistant-target='providerStatus']", text: /retention/i
    assert_select "select[data-assistant-target='providerSelect']", count: 0
    assert_select "button[data-assistant-target='startButton']", count: 0
    assert_select "form[data-action*='assistant#submitMessage'] textarea"
    assert_select "details[data-assistant-target='contextDisclosure'] > summary", text: /Add Hunter context/i
    assert_select "[data-assistant-target='disclosurePreview']"
    assert_select "[data-assistant-target='drafts'][aria-live='polite']"
    assert_select "[data-assistant-target='historyMenu'][role='menu'][hidden]"
    assert_select "dialog[data-assistant-target='renameDialog'] input[data-assistant-target='renameInput'][maxlength='200']"
    assert_select "button[data-assistant-target='fontDecrease'][aria-label='Decrease chat text size']"
    assert_select "button[data-assistant-target='fontIncrease'][aria-label='Increase chat text size']"
    assert_select "#hunter-assistant-delete-consequence", text: /Provider or backup copies may remain/i
    assert_select "[data-controller='toaster'].bottom-24"

    importmap = JSON.parse(css_select("script[type='importmap']").sole.text)
    assert_match %r{\A/assets/lib/assistant_markdown-[a-f0-9]+\.js\z},
      importmap.fetch("imports").fetch("#assistant-markdown")

    dompurify_path = importmap.fetch("imports").fetch("dompurify")
    get dompurify_path
    assert_response :success
    assert_equal "text/javascript", response.media_type
  end

  test "shell discloses non-secret reads and permission-free bounded authoring" do
    sign_in_as(@admin)
    get root_path

    assert_response :success
    assert_select "#hunter-assistant-capability-disclosure", text: /read non-secret Hunter data/i
    assert_select "#hunter-assistant-capability-disclosure", text: /create and explicitly edit validated Whiterabbit templates and Ansible playbooks without a confirmation prompt/i
    assert_select "#hunter-assistant-capability-disclosure", text: /never delete or run/i
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
