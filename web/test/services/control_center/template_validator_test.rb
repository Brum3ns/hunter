require "test_helper"

class ControlCenter::TemplateValidatorTest < ActiveSupport::TestCase
  V = ControlCenter::TemplateValidator

  test "accepts a command with valid operator and args" do
    cmds = [{ "command" => "httpx", "args" => ["-silent", "-json"], "operator" => "" }]
    assert_empty V.call(cmds)
  end

  test "rejects an empty command list" do
    assert_includes V.call([]), "at least one command is required"
  end

  test "allows any command by default (no shell, no allowlist)" do
    assert_empty V.call([{ "command" => "rm", "args" => ["-rf", "/tmp/x"], "operator" => "" }])
    assert_empty V.call([{ "command" => "/usr/local/bin/mytool", "args" => [], "operator" => "" }])
  end

  test "rejects an invalid operator" do
    errors = V.call([{ "command" => "httpx", "args" => [], "operator" => ";" }])
    assert(errors.any? { |e| e.include?("operator") })
  end

  test "allows spaces, quotes, and shell metacharacters in args (passed literally as argv)" do
    cmds = [{ "command" => "sh-like", "args" => ["; cat /etc/passwd", "a|b", "$HOME", "'quoted'", "foo bar"], "operator" => "" }]
    assert_empty V.call(cmds)
  end

  test "accepts placeholder tokens in args" do
    cmds = [{ "command" => "httpx", "args" => ["-l", "__TARGET_FILE__", "-o", "__UUID__.json"], "operator" => "" }]
    assert_empty V.call(cmds)
  end

  test "rejects a NUL or newline in args" do
    errors = V.call([{ "command" => "httpx", "args" => ["a\nb"], "operator" => "" }])
    assert(errors.any? { |e| e.include?("args[0]") })
  end

  test "rejects a newline in the command name" do
    errors = V.call([{ "command" => "ht\ntpx", "args" => [], "operator" => "" }])
    assert(errors.any? { |e| e.include?("command") && e.include?("forbidden") })
  end

  test "allowlist is nil when the env is empty or unset" do
    assert_nil V.allowlist
  end

  test "enforces the allowlist only when the env is set" do
    ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"] = "httpx, nuclei"
    assert_equal %w[httpx nuclei], V.allowlist
    assert_empty V.call([{ "command" => "httpx", "args" => [], "operator" => "" }])
    errors = V.call([{ "command" => "rm", "args" => [], "operator" => "" }])
    assert(errors.any? { |e| e.include?("is not allowed") })
  ensure
    ENV.delete("CONTROL_CENTER_COMMAND_ALLOWLIST")
  end
end
