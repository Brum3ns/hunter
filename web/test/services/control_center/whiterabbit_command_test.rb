require "test_helper"

class ControlCenter::WhiterabbitCommandTest < ActiveSupport::TestCase
  W = ControlCenter::WhiterabbitCommand

  test "builds argv with the standalone subcommand and passes allowed flags" do
    captured = nil
    stub_methods(W, capture: ->(argv) { captured = argv; ["ok", "", 0] }) do
      result = W.execute(["-run", "probe", "-target", "/tmp/t.txt"], timeout: 5, max_output: 1024)
      assert_nil result.error
      assert_equal 0, result.exit_status
    end
    assert_equal W.bin, captured[0]
    assert_equal "standalone", captured[1]
    assert_includes captured, "-run"
    assert_includes captured, "probe"
  end

  test "allows -folder-nfs so chunked sends can pass a chunk output dir" do
    captured = nil
    stub_methods(W, capture: ->(argv) { captured = argv; ["ok", "", 0] }) do
      result = W.execute(["-run", "probe", "-folder-nfs", "/tmp/nfs"], timeout: 5, max_output: 1024)
      assert_nil result.error
    end
    assert_includes captured, "-folder-nfs"
    assert_includes captured, "/tmp/nfs"
  end

  test "rejects a flag not on the allowlist without executing" do
    called = false
    stub_methods(W, capture: ->(_argv) { called = true; ["", "", 0] }) do
      result = W.execute(["-exec-something", "x"], timeout: 5, max_output: 1024)
      assert_match(/not allowed/, result.error)
    end
    assert_not called
  end

  test "rejects a NUL or newline in any token" do
    result = W.execute(["-run", "a\nb"], timeout: 5, max_output: 1024)
    assert_match(/NUL or newline/, result.error)
  end

  test "clips stdout to max_output" do
    stub_methods(W, capture: ->(_argv) { ["x" * 5000, "", 0] }) do
      result = W.execute(["-check-rabbitmq"], timeout: 5, max_output: 100)
      assert_equal 100, result.stdout.bytesize
      assert result.output_truncated
    end
  end

  test "reports a timeout as an error" do
    stub_methods(W, capture: ->(_argv) { sleep 2; ["", "", 0] }) do
      result = W.execute(["-check-rabbitmq"], timeout: 0, max_output: 100)
      assert_match(/timed out/, result.error)
    end
  end
end
