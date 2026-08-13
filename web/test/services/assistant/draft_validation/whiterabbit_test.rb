require "test_helper"

class Assistant::DraftValidation::WhiterabbitTest < ActiveSupport::TestCase
  VALID_DRAFT = {
    "name" => "HTTP probe",
    "kind" => "cmdscript",
    "description" => "Probe selected targets",
    "commands" => [
      { "command" => "httpx", "args" => [ "-silent", "-l", "__TARGET_FILE__" ], "operator" => "" }
    ]
  }.freeze

  test "fails closed when the assistant command allowlist is unconfigured" do
    stub_methods(ControlCenter::TemplateValidator, allowlist: nil) do
      result = Assistant::DraftValidation::Whiterabbit.call(VALID_DRAFT.except("description"))

      refute result.valid?
      assert_includes result.codes, "assistant_command_policy_unconfigured"
      assert_nil result.normalized
    end
  end

  test "returns a closed normalized draft after existing validation" do
    stub_methods(ControlCenter::TemplateValidator, allowlist: [ "httpx" ]) do
      result = Assistant::DraftValidation::Whiterabbit.call(VALID_DRAFT)

      assert result.valid?
      assert_equal VALID_DRAFT, result.normalized
      assert_equal "whiterabbit-v1", result.validation_version
      assert_empty result.codes
      assert_empty result.messages
    end
  end

  test "rejects extra fields and non-string arguments before domain validation" do
    domain_validator_called = false
    draft = VALID_DRAFT.deep_dup
    draft["execute"] = true
    draft["commands"][0]["args"] = [ { "secret" => "value" } ]

    stub_methods(ControlCenter::TemplateValidator,
      allowlist: [ "httpx" ],
      call: ->(*) { domain_validator_called = true; [] }) do
      result = Assistant::DraftValidation::Whiterabbit.call(draft)

      refute result.valid?
      assert_includes result.codes, "whiterabbit_draft_unknown_field"
      assert_includes result.codes, "whiterabbit_arg_invalid"
      refute domain_validator_called
    end
  end

  test "redacts rejected command names and arguments" do
    draft = VALID_DRAFT.deep_dup
    draft["commands"][0] = {
      "command" => "unapproved-secret-tool",
      "args" => [ "--mode=fast" ],
      "operator" => ""
    }

    stub_methods(ControlCenter::TemplateValidator, allowlist: [ "httpx" ]) do
      result = Assistant::DraftValidation::Whiterabbit.call(draft)

      refute result.valid?
      assert_includes result.codes, "assistant_command_not_allowed"
      refute_includes result.messages.join(" "), "unapproved-secret-tool"
      refute_includes result.messages.join(" "), "unapproved-secret-tool"
    end
  end

  test "rejects inline HTTP credentials in an otherwise allowlisted command" do
    draft = VALID_DRAFT.deep_dup
    draft["commands"][0]["args"] = [ "-H", "Cookie: session=do-not-persist" ]

    stub_methods(ControlCenter::TemplateValidator, allowlist: [ "httpx" ]) do
      result = Assistant::DraftValidation::Whiterabbit.call(draft)

      refute result.valid?
      assert_includes result.codes, "artifact_secret_material_not_allowed"
      refute_includes result.messages.join(" "), "do-not-persist"
    end
  end

  test "never persists or sends a template" do
    stub_methods(ControlCenter::TemplateValidator, allowlist: [ "httpx" ]) do
      assert_no_difference -> { ControlCenter::Template.count } do
        Assistant::DraftValidation::Whiterabbit.call(VALID_DRAFT)
      end
    end
  end
end
