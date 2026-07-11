require "test_helper"

class ControlCenter::TemplateValidatorTest < ActiveSupport::TestCase
  V = ControlCenter::TemplateValidator

  test "accepts an allowlisted command with valid operator and args" do
    cmds = [{ "command" => "httpx", "args" => ["-silent", "-json"], "operator" => "" }]
    assert_empty V.call(cmds)
  end

  test "rejects an empty command list" do
    assert_includes V.call([]), "at least one command is required"
  end

  test "rejects a command not on the allowlist" do
    errors = V.call([{ "command" => "rm", "args" => ["-rf", "/"], "operator" => "" }])
    assert(errors.any? { |e| e.include?("is not allowed") })
  end

  test "rejects an invalid operator" do
    errors = V.call([{ "command" => "httpx", "args" => [], "operator" => ";" }])
    assert(errors.any? { |e| e.include?("operator") })
  end

  test "rejects shell metacharacters in args" do
    errors = V.call([{ "command" => "httpx", "args" => ["; cat /etc/passwd"], "operator" => "" }])
    assert(errors.any? { |e| e.include?("args[0]") })
  end

  test "rejects a NUL or newline in args" do
    errors = V.call([{ "command" => "httpx", "args" => ["a\nb"], "operator" => "" }])
    assert(errors.any? { |e| e.include?("args[0]") })
  end

  test "allowlist honors the env override" do
    ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"] = "foo, bar"
    assert_equal %w[foo bar], V.allowlist
  ensure
    ENV.delete("CONTROL_CENTER_COMMAND_ALLOWLIST")
  end
end
