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

  test "accepts every structurally valid command even when the retired setting is present" do
    original = ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"]
    ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"] = "httpx"

    commands = %w[nuclei dalfox katana feroxbuster gowitness dnsx bash python sudo docker rm]
    commands << "/opt/tools/custom-scanner"

    commands.each do |name|
      assert_empty V.call([{ "command" => name, "args" => [], "operator" => "" }]), name
    end
  ensure
    ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"] = original
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

  test "rejects NUL, CR, and LF in command names and arguments" do
    { "NUL" => "\0", "CR" => "\r", "LF" => "\n" }.each do |label, character|
      command_errors = V.call([
        { "command" => "bad#{character}name", "args" => [], "operator" => "" }
      ])
      assert_includes command_errors,
        "commands[0].command contains a forbidden character (NUL or newline)", label

      argument_errors = V.call([
        { "command" => "httpx", "args" => [ "bad#{character}argument" ], "operator" => "" }
      ])
      assert_includes argument_errors,
        "commands[0].args[0] contains a forbidden character (NUL or newline)", label
    end
  end

  test "accepts exactly 50 commands and rejects 51" do
    valid_commands = Array.new(50) do |index|
      { "command" => "command-#{index}", "args" => [], "operator" => "" }
    end

    assert_empty V.call(valid_commands)
    assert_equal [ "too many commands (max 50)" ],
      V.call(valid_commands + [ { "command" => "command-50", "args" => [], "operator" => "" } ])
  end

  test "accepts exactly 200 arguments and rejects 201" do
    valid_arguments = Array.new(200) { |index| "argument-#{index}" }
    command = ->(args) { [ { "command" => "httpx", "args" => args, "operator" => "" } ] }

    assert_empty V.call(command.call(valid_arguments))
    assert_equal [ "commands[0] has too many args (max 200)" ],
      V.call(command.call(valid_arguments + [ "argument-200" ]))
  end

  test "accepts a 4096-character argument and rejects 4097 characters" do
    command = ->(argument) { [ { "command" => "httpx", "args" => [ argument ], "operator" => "" } ] }

    assert_empty V.call(command.call("a" * 4_096))
    assert_equal [ "commands[0].args[0] is too long (max 4096)" ],
      V.call(command.call("a" * 4_097))
  end
end
