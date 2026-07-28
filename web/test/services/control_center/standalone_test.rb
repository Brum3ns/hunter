require "test_helper"

class ControlCenter::StandaloneTest < ActiveSupport::TestCase
  W = ControlCenter::WhiterabbitCommand
  Result = Struct.new(:exit_status, :stdout, :stderr, :error, keyword_init: true)

  def template
    ControlCenter::Template.new(name: "probe", commands: [{ "command" => "httpx", "args" => ["-silent"], "operator" => "" }])
  end

  test "submit passes the caller's target_file path through to the binary flags" do
    template = ControlCenter::Template.new(name: "httpx", commands: [{ "command" => "httpx", "args" => [] }])
    captured = nil
    stub_methods(ControlCenter::TemplateRenderer, to_yaml: "name: httpx\n") do
      stub_methods(ControlCenter::WhiterabbitCommand,
        execute: ->(flags, **_) { captured = flags; Result.new(exit_status: 0, stdout: "ok", stderr: "", error: nil) }) do
        Dir.mktmpdir do |d|
          tf = File.join(d, "targets.txt")
          File.write(tf, "a.com\nb.com\n")
          result = ControlCenter::Standalone.submit(template: template, target_file: tf,
                     queue_name: "test", target_chunk: 100, delay: 0)
          assert_equal 0, result.exit_status
        end
      end
    end
    assert_includes captured, "-target"
    assert_equal captured[captured.index("-target") + 1].then { |p| File.basename(p) }, "targets.txt"
    assert_equal "100", captured[captured.index("-target-chunk") + 1]
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
      Dir.mktmpdir do |d|
        tf = File.join(d, "targets.txt")
        File.write(tf, "a.com\nb.com\n")
        result = ControlCenter::Standalone.submit(template: template, target_file: tf, queue_name: "scan", target_chunk: 10, delay: 5)
        assert_equal 0, result.exit_status
      end
    end
    assert_includes captured_flags, "-run"
    assert_includes captured_flags, "probe"
    assert_equal "scan", captured_flags[captured_flags.index("-queue-name") + 1]
    assert_equal "10", captured_flags[captured_flags.index("-target-chunk") + 1]
    # A chunked send needs -folder-nfs pointing at a real dir or whiterabbit aborts.
    assert_includes captured_flags, "-folder-nfs"
    assert_match(/httpx/, rendered)
  end

  test "submit passes an existing -folder-nfs directory for chunking" do
    nfs_ok = nil
    fake = lambda do |flags, timeout:, max_output:|
      dir = flags[flags.index("-folder-nfs") + 1]
      nfs_ok = File.directory?(dir)
      W::Result.new(exit_status: 0, stdout: "", stderr: "", error: nil)
    end
    stub_methods(W, execute: fake) do
      Dir.mktmpdir do |d|
        tf = File.join(d, "targets.txt")
        File.write(tf, "a.com\n")
        ControlCenter::Standalone.submit(template: template, target_file: tf, queue_name: "test", target_chunk: 1)
      end
    end
    assert nfs_ok, "-folder-nfs must point at a directory that exists at exec time"
  end

  test "submit passes the caller's target_file to the binary flags" do
    seen = nil
    fake = lambda do |flags, timeout:, max_output:|
      seen = File.read(flags[flags.index("-target") + 1])
      W::Result.new(exit_status: 0, stdout: "", stderr: "", error: nil)
    end
    stub_methods(W, execute: fake) do
      Dir.mktmpdir do |d|
        tf = File.join(d, "targets.txt")
        File.write(tf, "a.com\nb.com")
        ControlCenter::Standalone.submit(template: template, target_file: tf, queue_name: "test")
      end
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
