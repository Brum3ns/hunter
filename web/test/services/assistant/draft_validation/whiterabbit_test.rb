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

  test "returns a closed normalized draft after existing validation" do
    result = Assistant::DraftValidation::Whiterabbit.call(VALID_DRAFT)

    assert result.valid?
    assert_equal VALID_DRAFT, result.normalized
    assert_equal "whiterabbit-v2", result.validation_version
    assert_empty result.codes
    assert_empty result.messages
  end

  test "rejects extra fields and non-string arguments before domain validation" do
    domain_validator_called = false
    draft = VALID_DRAFT.deep_dup
    draft["execute"] = true
    draft["commands"][0]["args"] = [ { "secret" => "value" } ]

    stub_methods(ControlCenter::TemplateValidator,
      call: ->(*) { domain_validator_called = true; [] }) do
      result = Assistant::DraftValidation::Whiterabbit.call(draft)

      refute result.valid?
      assert_includes result.codes, "whiterabbit_draft_unknown_field"
      assert_includes result.codes, "whiterabbit_arg_invalid"
      refute domain_validator_called
    end
  end

  test "accepts an arbitrary command when a stale retired allowlist is present" do
    original = ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"]
    ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"] = "httpx"
    draft = VALID_DRAFT.deep_dup
    draft["commands"] = [
      { "command" => "bash", "args" => [ "-c", "printf ok" ], "operator" => "" }
    ]

    result = Assistant::DraftValidation::Whiterabbit.call(draft)

    assert result.valid?, result.codes.inspect
    assert_equal "bash", result.normalized.dig("commands", 0, "command")
    assert_equal "whiterabbit-v2", result.validation_version
    assert_empty result.codes
  ensure
    ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"] = original
  end

  test "accepts a 255-character command name and rejects 256 characters" do
    maximum = VALID_DRAFT.deep_dup
    maximum["commands"][0]["command"] = "x" * 255

    accepted = Assistant::DraftValidation::Whiterabbit.call(maximum)

    assert accepted.valid?, accepted.codes.inspect
    assert_equal "x" * 255, accepted.normalized.dig("commands", 0, "command")

    oversized = VALID_DRAFT.deep_dup
    oversized["commands"][0]["command"] = "x" * 256

    rejected = Assistant::DraftValidation::Whiterabbit.call(oversized)

    refute rejected.valid?
    assert_equal [ "whiterabbit_command_invalid" ], rejected.codes
    assert_nil rejected.normalized
  end

  test "rejects inline HTTP credentials in an otherwise structurally valid command" do
    draft = VALID_DRAFT.deep_dup
    draft["commands"][0]["args"] = [ "-H", "Cookie: session=do-not-persist" ]

    result = Assistant::DraftValidation::Whiterabbit.call(draft)

    refute result.valid?
    assert_includes result.codes, "artifact_secret_material_not_allowed"
    refute_includes result.messages.join(" "), "do-not-persist"
  end

  test "never persists or sends a template" do
    assert_no_difference -> { ControlCenter::Template.count } do
      Assistant::DraftValidation::Whiterabbit.call(VALID_DRAFT)
    end
  end
end
