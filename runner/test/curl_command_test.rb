require "minitest/autorun"
require_relative "../curl_command"

class RunnerCurlCommandTest < Minitest::Test
  def test_accepts_plain_https
    ok, argv = Sandbox::CurlCommand.validate("curl https://example.com")
    assert ok
    assert_equal %w[curl https://example.com], argv
  end

  def test_rejects_file_scheme
    ok, = Sandbox::CurlCommand.validate("curl file:///etc/passwd")
    refute ok
  end

  def test_rejects_output_flag
    ok, = Sandbox::CurlCommand.validate("curl -o /tmp/x https://example.com")
    refute ok
  end

  def test_execute_never_runs_invalid
    called = false
    Sandbox::CurlCommand.define_singleton_method(:capture) { |*| called = true; ["", "", 0] }
    r = Sandbox::CurlCommand.execute("curl file:///etc/passwd", max_time: 5, max_output: 100)
    refute called
    refute_nil r.error
  end

  def test_execute_injects_include_so_response_headers_are_captured
    seen = nil
    Sandbox::CurlCommand.define_singleton_method(:capture) { |argv, **| seen = argv; ["", "", 0] }
    Sandbox::CurlCommand.execute("curl https://example.com", max_time: 5, max_output: 100)
    assert_includes seen, "--include"
  end

  def test_execute_does_not_duplicate_include
    seen = nil
    Sandbox::CurlCommand.define_singleton_method(:capture) { |argv, **| seen = argv; ["", "", 0] }
    Sandbox::CurlCommand.execute("curl -i https://example.com", max_time: 5, max_output: 100)
    assert_equal 1, seen.count { |a| a == "-i" || a == "--include" }
  end
end
