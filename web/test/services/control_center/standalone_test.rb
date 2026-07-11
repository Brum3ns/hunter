require "test_helper"

class ControlCenter::StandaloneTest < ActiveSupport::TestCase
  W = ControlCenter::WhiterabbitCommand

  def template
    ControlCenter::Template.new(name: "probe", commands: [{ "command" => "httpx", "args" => ["-silent"], "operator" => "" }])
  end

  test "submit renders the template into the cmdscript folder and passes run flags" do
    captured_flags = nil
    rendered = nil
    fake = lambda do |flags, timeout:, max_output:|
      captured_flags = flags
      dir = flags[flags.index("-folder-cmdscript") + 1]
      rendered = File.read(File.join(dir, "probe.yaml"))
      W::Result.new(exit_status: 0, stdout: "sent", stderr: "", error: nil)
    end
    stub_methods(W, execute: fake) do
      result = ControlCenter::Standalone.submit(template: template, targets: %w[a.com b.com], queue_name: "scan", target_chunk: 10, delay: 5)
      assert_equal 0, result.exit_status
    end
    assert_includes captured_flags, "-run"
    assert_includes captured_flags, "probe"
    assert_equal "scan", captured_flags[captured_flags.index("-queue-name") + 1]
    assert_equal "10", captured_flags[captured_flags.index("-target-chunk") + 1]
    assert_match(/httpx/, rendered)
  end

  test "submit writes targets to the target file" do
    seen = nil
    fake = lambda do |flags, timeout:, max_output:|
      seen = File.read(flags[flags.index("-target") + 1])
      W::Result.new(exit_status: 0, stdout: "", stderr: "", error: nil)
    end
    stub_methods(W, execute: fake) do
      ControlCenter::Standalone.submit(template: template, targets: %w[a.com b.com], queue_name: "test")
    end
    assert_equal "a.com\nb.com", seen
  end

  test "health maps check results to ok booleans" do
    fake = lambda do |flags, timeout:, max_output:|
      W::Result.new(exit_status: (flags == ["-check-rabbitmq"] ? 0 : 1), stdout: "", stderr: "down", error: nil)
    end
    stub_methods(W, execute: fake) do
      h = ControlCenter::Standalone.health
      assert h[:rabbitmq][:ok]
      assert_not h[:mongo][:ok]
    end
  end
end
