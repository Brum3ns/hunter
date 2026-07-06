require "test_helper"

class Sandbox::CurlCommandTest < ActiveSupport::TestCase
  def validate(cmd) = Sandbox::CurlCommand.validate(cmd)

  test "accepts a plain https curl" do
    ok, argv = validate("curl https://example.com/api")
    assert ok
    assert_equal %w[curl https://example.com/api], argv
  end

  test "accepts curl with --url and safe flags" do
    ok, argv = validate("curl -sS -H 'Accept: application/json' --url https://example.com")
    assert ok
    assert_includes argv, "https://example.com"
  end

  test "rejects empty command" do
    ok, reason = validate("   ")
    refute ok
    assert_match(/empty/i, reason)
  end

  test "rejects non-curl program" do
    ok, reason = validate("wget https://example.com")
    refute ok
    assert_match(/curl/i, reason)
  end

  test "rejects unparseable command" do
    ok, reason = validate("curl 'unterminated")
    refute ok
    assert_match(/parse/i, reason)
  end

  test "rejects a newline in the command" do
    ok, reason = validate("curl https://example.com\nrm -rf /")
    refute ok
    assert_match(/newline|invalid/i, reason)
  end

  test "rejects non-http schemes" do
    ok, reason = validate("curl file:///etc/passwd")
    refute ok
    assert_match(/http/i, reason)
  end

  test "rejects when no http url is present" do
    ok, reason = validate("curl -sS")
    refute ok
    assert_match(/url/i, reason)
  end

  test "rejects output-writing flags" do
    %w[-o --output -O --remote-name -K --config -D --dump-header -c --cookie-jar].each do |flag|
      ok, reason = validate("curl #{flag} x https://example.com")
      refute ok, "expected #{flag} to be rejected"
      assert_match(/not allowed|denied|flag/i, reason)
    end
  end

  test "rejects data flags that read a file" do
    ok, reason = validate("curl -d @/etc/passwd https://example.com")
    refute ok
    assert_match(/file/i, reason)
  end

  test "rejects too many arguments" do
    args = (["curl"] + Array.new(500, "-H") + ["https://example.com"]).join(" ")
    ok, reason = validate(args)
    refute ok
    assert_match(/many|long/i, reason)
  end

  test "accepts a realistic curl with many headers" do
    args = (["curl"] + Array.new(40) { |i| "-H 'X-H#{i}: v'" } + ["https://example.com"]).join(" ")
    ok, = validate(args)
    assert ok, "a curl with 40 headers should be accepted"
  end

  test "execute never runs invalid input" do
    called = false
    stub_methods(Sandbox::CurlCommand, capture: ->(*, **) { called = true; ["", "", 0] }) do
      result = Sandbox::CurlCommand.execute("curl file:///etc/passwd", max_time: 5, max_output: 1000)
      refute called
      refute_nil result.error
      assert_nil result.exit_status
    end
  end

  test "execute injects safety flags and returns a Result" do
    seen = nil
    stub_methods(Sandbox::CurlCommand, capture: ->(argv, **) { seen = argv; ["body", "", 0] }) do
      result = Sandbox::CurlCommand.execute("curl https://example.com", max_time: 7, max_output: 1000)
      assert_equal 0, result.exit_status
      assert_equal "body", result.stdout
      assert_includes seen, "--max-time"
      assert_includes seen, "7"
      assert_includes seen, "-sS"
    end
  end

  test "execute truncates output over the cap" do
    stub_methods(Sandbox::CurlCommand, capture: ->(*, **) { ["x" * 5000, "", 0] }) do
      result = Sandbox::CurlCommand.execute("curl https://example.com", max_time: 5, max_output: 100)
      assert_equal 100, result.stdout.bytesize
      assert result.output_truncated
    end
  end
end
