require "test_helper"

class Assistant::Machine::SensitiveDataTest < ActiveSupport::TestCase
  test "redacts secret-bearing HTTP headers while preserving useful evidence" do
    result = Assistant::Machine::SensitiveData.text(<<~HTTP)
      GET /admin HTTP/1.1
      Host: app.example.test
      Authorization: Bearer do-not-return
      Cookie: session=do-not-return
      X-Trace: trace-123
    HTTP

    assert result.redacted
    assert_includes result.value, "GET /admin"
    assert_includes result.value, "Host: app.example.test"
    assert_includes result.value, "Authorization: [REDACTED]"
    assert_includes result.value, "Cookie: [REDACTED]"
    refute_includes result.value, "do-not-return"
  end

  test "returns closed bounded response headers and hides sensitive values" do
    headers = Assistant::Machine::SensitiveData.headers(
      "Server" => "nginx", "Set-Cookie" => "session=secret", "X-Trace" => "abc"
    )

    assert_equal [ "Server", "Set-Cookie", "X-Trace" ], headers.map { |header| header.fetch("name") }
    assert_equal "nginx", headers[0].fetch("value")
    assert_nil headers[1].fetch("value")
    assert_equal true, headers[1].fetch("redacted")
  end

  test "fails closed for private keys invalid encoding and residual secrets" do
    assert_nil Assistant::Machine::SensitiveData.text("-----BEGIN PRIVATE KEY-----\nabc").value
    invalid = "bad".dup.force_encoding(Encoding::UTF_16LE)
    assert_nil Assistant::Machine::SensitiveData.text(invalid).value
    assert_nil Assistant::Machine::SensitiveData.text("AKIAABCDEFGHIJKLMNOP").value
    assert_nil Assistant::Machine::SensitiveData.text("SECRET-EXTRACTED-CREDENTIALS").value
  end

  test "redacts common inline credentials URLs and JWT values" do
    result = Assistant::Machine::SensitiveData.text(
      "password=hunter https://user:pass@example.test eyJabcdefgh.ijklmnop.qrstuvwx"
    )

    assert result.redacted
    refute_includes result.value, "hunter"
    refute_includes result.value, "user:pass"
    refute_includes result.value, "eyJabcdefgh"
  end

  test "redacts inline cookie headers and OAuth credential assignments" do
    result = Assistant::Machine::SensitiveData.text(
      "curl -H 'Cookie: session=do-not-return' / client_secret=also-secret refresh_token: third-secret"
    )

    assert result.redacted
    refute_includes result.value, "do-not-return"
    refute_includes result.value, "also-secret"
    refute_includes result.value, "third-secret"
  end

  test "sanitizes every nested payload string without changing its shape" do
    result = Assistant::Machine::SensitiveData.payload(
      { "items" => [ {
        "title" => "Cookie: session=do-not-return", "status" => 200,
        "client_secret" => "structured-do-not-return"
      } ] }
    )

    assert result.redacted
    assert_equal 200, result.value.dig("items", 0, "status")
    assert_includes result.value.dig("items", 0, "title"), "[REDACTED]"
    assert_equal "[REDACTED]", result.value.dig("items", 0, "client_secret")
    refute_includes result.value.to_json, "do-not-return"
  end

  test "bounds text and rejects control bytes" do
    result = Assistant::Machine::SensitiveData.text("a" * 20, max_bytes: 10)
    assert_equal "a" * 10, result.value
    assert result.redacted
    assert_nil Assistant::Machine::SensitiveData.text("ok\u0000bad").value
  end

  test "structured evidence rejects sensitive keys before JSON serialization" do
    unsafe = Assistant::Machine::SensitiveData.json("result" => "ok", "api_key" => "do-not-return")
    safe = Assistant::Machine::SensitiveData.json("title" => "Admin", "status" => 200)

    assert_nil unsafe.value
    assert unsafe.redacted
    assert_equal '{"title":"Admin","status":200}', safe.value
  end

  test "target response headers exclude unrecognized names and cap count" do
    raw = { "Server" => "nginx", "X-Unreviewed" => "opaque", "Authorization" => "Bearer secret" }
    60.times { |index| raw["X-Request-Id"] = index.to_s }
    headers = Assistant::Machine::SensitiveData.response_headers(raw)

    assert_equal [ "Server", "Authorization", "X-Request-Id" ], headers.map { |header| header.fetch("name") }
    refute_includes headers.map { |header| header.fetch("name") }, "X-Unreviewed"
    assert_nil headers[1].fetch("value")
  end
end
