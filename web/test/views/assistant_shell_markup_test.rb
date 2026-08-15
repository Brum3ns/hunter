require "minitest/autorun"
require "nokogiri"
require "pathname"

class AssistantShellMarkupTest < Minitest::Test
  TEMPLATE = Pathname(__dir__).join("../../app/views/layouts/_assistant.html.erb").freeze
  STYLESHEET = Pathname(__dir__).join("../../app/assets/tailwind/application.css").freeze

  def setup
    @document = Nokogiri::HTML5.fragment(TEMPLATE.read)
  end

  def test_desktop_shell_exposes_one_accessible_anchored_resize_control
    panel = @document.at_css("#hunter-assistant-panel.assistant-panel[data-assistant-target='panel']")
    handle = @document.at_css("button[data-assistant-target='resizeHandle'][aria-label='Resize Hunter assistant']")

    assert panel
    assert handle
    assert_includes handle["data-action"], "pointerdown->assistant#startResize"
    assert_includes handle["data-action"], "keydown->assistant#resizeWithKeyboard"
    assert_equal "ArrowLeft ArrowRight ArrowUp ArrowDown", handle["aria-keyshortcuts"]
    assert_equal "Resize Hunter assistant", handle["aria-label"]
    assert_equal "hunter-assistant-resize-help", handle["aria-describedby"]
    assert @document.at_css("#hunter-assistant-resize-status[data-assistant-target='resizeStatus'][role='status'][aria-live='polite']")
    assert @document.at_css("[data-assistant-resize-label]"), "resize affordance needs visible help"
  end

  def test_history_menu_rename_dialog_and_font_controls_are_accessible
    menu = @document.at_css("[data-assistant-target='historyMenu'][role='menu'][hidden]")
    dialog = @document.at_css("dialog[data-assistant-target='renameDialog'][aria-labelledby='hunter-assistant-rename-title']")

    assert menu
    assert_includes menu["data-action"], "keydown->assistant#handleHistoryMenuKeydown"
    assert menu.at_css("button[data-action='assistant#beginRename'][role='menuitem']")
    assert menu.at_css("button[data-action='assistant#moveHistoryUp'][role='menuitem']")
    assert menu.at_css("button[data-action='assistant#moveHistoryDown'][role='menuitem']")
    assert menu.at_css("button[data-action='assistant#deleteHistoryConversation'][role='menuitem']")
    assert dialog
    assert dialog.at_css("form[data-action='submit->assistant#submitRename'] input[data-assistant-target='renameInput'][maxlength='200']")
    assert dialog.at_css("button[data-assistant-target='renameCancel'][data-action='assistant#cancelRename']")
    assert dialog.at_css("button[data-assistant-target='renameSubmit'][type='submit']")
    assert @document.at_css("button[data-assistant-target='fontDecrease'][aria-label='Decrease chat text size']")
    assert @document.at_css("button[data-assistant-target='fontIncrease'][aria-label='Increase chat text size']")
    assert @document.at_css("[data-assistant-target='fontScaleStatus'][role='status'][aria-live='polite']")
  end

  def test_history_toggle_controls_the_labelled_sidebar
    sidebar = @document.at_css("#hunter-assistant-history[data-assistant-target='historySidebar']")
    toggle = @document.at_css("button[data-assistant-target='historyToggle']")

    assert sidebar
    assert_equal "Assistant conversations", sidebar["aria-label"]
    assert_equal sidebar["id"], toggle["aria-controls"]
  end

  def test_new_chat_keeps_an_unconditional_name_when_collapsed_text_is_hidden
    new_chat = @document.at_css("button[data-action='assistant#showNewConversation']")

    assert new_chat.at_css("[data-history-expanded-only]")
    assert_equal "New chat", new_chat["aria-label"]
  end

  def test_direct_provider_controls_are_one_click_accessible_and_model_free
    buttons = @document.css("button[data-assistant-target='providerButton'][data-action='assistant#startConversation']")

    assert_equal %w[codex claude_code], buttons.map { |button| button["data-backend"] }
    assert_equal [ "Start an OpenAI conversation", "Start an Anthropic conversation" ],
      buttons.map { |button| button["aria-label"] }
    assert buttons.all? { |button| !button["title"].to_s.empty? }
    assert_equal [ "assistant/openai.svg", "assistant/anthropic.svg" ],
      buttons.map { |button| button.inner_html[/assistant\/(?:openai|anthropic)\.svg/] }
    refute @document.at_css("[data-assistant-target='providerSelect']")
    refute @document.at_css("[data-assistant-target='startButton']")
    refute_match(/provider and model/i, @document.text)
  end

  def test_delete_controls_share_the_explicit_retention_consequence
    disclosure = @document.at_css("#hunter-assistant-delete-consequence")

    assert_match(/permanently delete this local conversation/i, disclosure&.text)
    assert_match(/provider or backup copies may remain/i, disclosure&.text)
    assert @document.at_css("button[data-action='assistant#deleteConversation'][aria-describedby='hunter-assistant-delete-consequence']")
  end

  def test_assistant_shell_uses_strong_neutral_boundaries_without_cyan
    panel = @document.at_css("#hunter-assistant-panel")
    messages = @document.at_css("[data-assistant-target='messages']")

    assert_match(/border-zinc-(?:300|400|500)/, panel["class"])
    assert_match(/border-zinc-(?:200|300|400|500)/, messages["class"])
    assistant_classes = @document.css("[data-controller='assistant'] [class]").map { |node| node["class"] }.join(" ")
    refute_includes assistant_classes, "cyan-"
  end

  def test_markdown_typography_is_namespaced_and_uses_the_message_scale
    css = STYLESHEET.read

    assert_includes css, "font-size: calc(0.875rem * var(--assistant-message-scale, 1))"
    %w[h1 blockquote code pre table a].each do |element|
      assert_includes css, ".assistant-markdown #{element}", element
    end
  end

  def test_large_capability_and_context_controls_are_collapsed_disclosures
    capability = @document.at_css("details[data-assistant-target='capabilityDisclosure']:not([open])")
    context = @document.at_css("details[data-assistant-target='contextDisclosure']:not([open])")

    assert_equal "Data access & actions", capability&.at_css("summary")&.text&.strip
    assert_equal "Add Hunter context", context&.at_css("summary")&.text&.strip
  end

  def test_composer_discloses_keyboard_behavior_and_wires_growth
    input = @document.at_css("textarea[data-assistant-target='messageInput']")
    hint = @document.at_css("#hunter-assistant-composer-hint")

    assert_includes input["data-action"], "input->assistant#autosizeComposer"
    assert_includes input["data-action"], "keydown->assistant#handleComposerKeydown"
    assert_equal "Enter to send · Shift+Enter for a new line", hint.text.strip
  end
end
