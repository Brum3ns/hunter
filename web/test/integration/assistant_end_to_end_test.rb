require "test_helper"

class AssistantEndToEndTest < ActionDispatch::IntegrationTest
  SELECTED_RECORD_FIXTURE = Rails.root
    .join("../assistant/testdata/adversarial/selected_records.json").expand_path.freeze

  setup do
    @admin = users(:one)
    @original_admin_username = ENV["ADMIN_USERNAME"]
    @original_command_allowlist = ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"]
    @original_ansible_allowlist = ENV["ASSISTANT_ANSIBLE_MODULE_ALLOWLIST"]
    ENV["ADMIN_USERNAME"] = @admin.username
    ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"] = "httpx"
    ENV["ASSISTANT_ANSIBLE_MODULE_ALLOWLIST"] = "ansible.builtin.debug"
    Assistant::Setting.instance.enable!
    sign_in_as(@admin)
  end

  teardown do
    ENV["ADMIN_USERNAME"] = @original_admin_username
    ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"] = @original_command_allowlist
    ENV["ASSISTANT_ANSIBLE_MODULE_ALLOWLIST"] = @original_ansible_allowlist
  end

  test "adversarial selected-record fixtures have stable secret and control classifications" do
    cases = JSON.parse(SELECTED_RECORD_FIXTURE.read).fetch("cases")

    cases.each do |test_case|
      value = case test_case["generator"]
      when "oversized_string" then "x" * (Assistant::Context::SecretDetector::MAX_STRING_BYTES + 1)
      when "malformed_utf8" then "bad\xFFvalue".b.force_encoding(Encoding::UTF_8)
      else test_case.fetch("value")
      end
      actual = Assistant::Context::SecretDetector.detect(value)&.to_s
      if test_case["secret_expected"].nil?
        assert_nil actual, test_case.fetch("name")
      else
        assert_equal test_case.fetch("secret_expected"), actual, test_case.fetch("name")
      end
    end
  end
end
