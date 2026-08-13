require "minitest/autorun"
require "nokogiri"
require "pathname"

class AssistantShellMarkupTest < Minitest::Test
  TEMPLATE = Pathname(__dir__).join("../../app/views/layouts/_assistant.html.erb").freeze

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
