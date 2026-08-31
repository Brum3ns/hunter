require "test_helper"

class Api::V1::Assistant::Machine::VulnerabilitiesTest < ActionDispatch::IntegrationTest
  setup do
    @original_config_enabled = Assistant::Config.method(:enabled?)
    @original_admin_username = ENV["ADMIN_USERNAME"]
    ENV["ADMIN_USERNAME"] = users(:one).username
    Assistant::Config.define_singleton_method(:enabled?) { |*, **| true }
    Assistant::Setting.instance.enable!
    _identity, @service_token = Assistant::ServiceIdentity.generate!(
      name: "vulnerabilities-#{SecureRandom.hex(4)}", role: "mcp_reader"
    )
  end

  teardown do
    Assistant::Config.define_singleton_method(:enabled?, @original_config_enabled)
    ENV["ADMIN_USERNAME"] = @original_admin_username
  end

  test "list_vulnerabilities returns a bounded projection and count" do
    vuln = {
      "id" => "60f7c2d2b1a2c3d4e5f6a7b8",
      "metadata" => { "program" => "acme", "tool" => "burp", "date" => "2026-01-01T00:00:00Z" },
      "finding" => { "name" => "Reflected XSS", "severity" => "high", "type" => "xss", "cwe" => "CWE-79", "tags" => [ "xss" ] },
      "report" => { "status" => "triaged" },
      "target" => { "host" => "app.acme.test", "url" => "https://app.acme.test/x" },
      "poc" => { "confidence" => "confirmed" }
    }

    stub_methods(Vulnerabilities::MongoSource, all: [ vuln ], count: 1) do
      get "/api/v1/assistant/machine/vulnerabilities", params: { q: "xss" }, headers: headers
    end

    assert_response :success
    body = response.parsed_body
    assert_equal 1, body["count"]
    item = body["items"].first
    assert_equal %w[id version name severity status program], item.keys
    assert_equal "60f7c2d2b1a2c3d4e5f6a7b8", item["id"]
    assert_equal "Reflected XSS", item["name"]
    assert_equal "high", item["severity"]
    assert_equal "triaged", item["status"]
    assert_equal "acme", item["program"]
  end

  test "list_vulnerabilities is refused when its live capability is disabled" do
    Assistant::Setting.instance.update!(disabled_capability_tools: [ "list_vulnerabilities" ])

    get "/api/v1/assistant/machine/vulnerabilities", headers: headers

    assert_response :forbidden
    assert_equal "capability_disabled", response.parsed_body["error"]
  end

  test "get_vulnerability returns the full projection" do
    vuln = {
      "id" => "60f7c2d2b1a2c3d4e5f6a7b8",
      "metadata" => { "program" => "acme", "tool" => "burp", "asset" => "web", "date" => "2026-01-01T00:00:00Z", "description" => "A reflected XSS.", "impact" => "Session hijack" },
      "finding" => { "name" => "Reflected XSS", "severity" => "high", "type" => "xss", "cwe" => "CWE-79", "tags" => [ "xss" ] },
      "report" => { "status" => "triaged", "submitted" => "2026-01-01T00:00:00Z", "status_updated_at" => "2026-01-02T00:00:00Z" },
      "target" => { "host" => "app.acme.test", "url" => "https://app.acme.test/x", "ip" => "10.0.0.1", "port" => 443 },
      "poc" => { "confidence" => "confirmed" }
    }

    stub_methods(Vulnerabilities::MongoSource, find: vuln) do
      get "/api/v1/assistant/machine/vulnerabilities/60f7c2d2b1a2c3d4e5f6a7b8", headers: headers
    end

    assert_response :success
    result = response.parsed_body["vulnerability"]
    expected_keys = %w[
      id version name severity status program
      type cwe tags tool asset date description impact
      host url ip port target_input method submitted status_updated_at confidence
      evidence
    ]
    assert_equal expected_keys, result.keys
    assert_equal "Reflected XSS", result["name"]
    assert_equal "app.acme.test", result["host"]
    assert_equal "confirmed", result["confidence"]
    assert_equal "Session hijack", result["impact"]
  end

  test "get_vulnerability never projects secret or PII fields even when present on the source doc" do
    vuln = {
      "id" => "60f7c2d2b1a2c3d4e5f6a7b8",
      "metadata" => {
        "program" => "acme", "tool" => "burp", "asset" => "web", "date" => "2026-01-01T00:00:00Z",
        "description" => "desc", "impact" => "impact", "scan_id" => "SECRET-SCAN-ID-999"
      },
      "finding" => { "name" => "Reflected XSS", "severity" => "high", "type" => "xss", "cwe" => "CWE-79", "tags" => [ "xss" ] },
      "report" => {
        "status" => "triaged", "submitted" => "2026-01-01T00:00:00Z", "status_updated_at" => "2026-01-02T00:00:00Z",
        "status_updated_by" => "SECRET-OPERATOR-NAME"
      },
      "target" => { "host" => "app.acme.test", "url" => "https://app.acme.test/x", "ip" => "10.0.0.1", "port" => 443 },
      "poc" => {
        "confidence" => "confirmed",
        "curl" => "curl -H 'Authorization: Bearer SECRET-CURL-TOKEN' https://app.acme.test",
        "extracted" => "SECRET-EXTRACTED-CREDENTIALS",
        "llm_reasoning" => "SECRET-LLM-REASONING-INTERNAL"
      },
      "request" => {
        "request" => "GET / HTTP/1.1\r\nCookie: session=SECRET-COOKIE-VALUE\r\nAuthorization: Bearer SECRET-REQUEST-TOKEN\r\nX-Trace: useful\r\n\r\n",
        "response" => "HTTP/1.1 200 OK\r\nSet-Cookie: session=SECRET-RESPONSE-COOKIE\r\nServer: nginx\r\n\r\n"
      }
    }

    stub_methods(Vulnerabilities::MongoSource, find: vuln) do
      get "/api/v1/assistant/machine/vulnerabilities/60f7c2d2b1a2c3d4e5f6a7b8", headers: headers
    end

    assert_response :success
    result = response.parsed_body["vulnerability"]
    expected_keys = %w[
      id version name severity status program
      type cwe tags tool asset date description impact
      host url ip port target_input method submitted status_updated_at confidence
      evidence
    ]
    assert_equal expected_keys, result.keys

    %w[
      SECRET-SCAN-ID-999 SECRET-OPERATOR-NAME SECRET-CURL-TOKEN
      SECRET-EXTRACTED-CREDENTIALS SECRET-LLM-REASONING-INTERNAL
      SECRET-COOKIE-VALUE SECRET-REQUEST-TOKEN SECRET-RESPONSE-COOKIE
    ].each do |secret|
      refute_includes response.body, secret
    end
    assert_includes result.dig("evidence", "request"), "X-Trace: useful"
    assert_includes result.dig("evidence", "response"), "Server: nginx"
    assert_equal true, result.dig("evidence", "request_redacted")
    assert_includes result.dig("evidence", "curl"), "Authorization: [REDACTED]"
    assert_equal true, result.dig("evidence", "curl_redacted")
  end

  test "get_vulnerability releases the reservation on a miss" do
    stub_methods(Vulnerabilities::MongoSource, find: nil) do
      get "/api/v1/assistant/machine/vulnerabilities/000000000000000000000000", headers: headers
    end

    assert_response :not_found
  end

  private

  def headers(*)
    { "Authorization" => "Bearer #{@service_token}" }
  end
end
