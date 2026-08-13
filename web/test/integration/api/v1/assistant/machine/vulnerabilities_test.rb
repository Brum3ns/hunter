require "test_helper"

class Api::V1::Assistant::Machine::VulnerabilitiesTest < ActionDispatch::IntegrationTest
  setup do
    @original_config_enabled = Assistant::Config.method(:enabled?)
    Assistant::Config.define_singleton_method(:enabled?) { |*, **| true }
    Assistant::Setting.instance.enable!
    _identity, @service_token = Assistant::ServiceIdentity.generate!(
      name: "vulnerabilities-#{SecureRandom.hex(4)}", role: "mcp_reader"
    )
  end

  teardown do
    Assistant::Config.define_singleton_method(:enabled?, @original_config_enabled)
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
      get "/api/v1/assistant/machine/vulnerabilities", params: { q: "xss" }, headers: headers(read_grant)
    end

    assert_response :success
    body = response.parsed_body
    assert_equal 1, body["count"]
    item = body["items"].first
    assert_equal %w[id name severity status program], item.keys
    assert_equal "60f7c2d2b1a2c3d4e5f6a7b8", item["id"]
    assert_equal "Reflected XSS", item["name"]
    assert_equal "high", item["severity"]
    assert_equal "triaged", item["status"]
    assert_equal "acme", item["program"]
  end

  test "list_vulnerabilities is refused without the vulnerabilities scope" do
    grant = read_grant
    Assistant::TurnGrant.order(:id).last.update_column(:read_scopes, [])

    get "/api/v1/assistant/machine/vulnerabilities", headers: headers(grant)

    assert_response :forbidden
    assert_equal "scope_not_allowed", response.parsed_body["reason"]
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
      get "/api/v1/assistant/machine/vulnerabilities/60f7c2d2b1a2c3d4e5f6a7b8", headers: headers(read_grant)
    end

    assert_response :success
    result = response.parsed_body["vulnerability"]
    expected_keys = %w[
      id name severity status program
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
      get "/api/v1/assistant/machine/vulnerabilities/60f7c2d2b1a2c3d4e5f6a7b8", headers: headers(read_grant)
    end

    assert_response :success
    result = response.parsed_body["vulnerability"]
    expected_keys = %w[
      id name severity status program
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
      get "/api/v1/assistant/machine/vulnerabilities/000000000000000000000000", headers: headers(read_grant)
    end

    assert_response :not_found
    assert_equal 0, Assistant::TurnGrant.order(:id).last.reload.reserved_bytes
  end

  private

  def read_grant
    Assistant::Grants::Issuer.call(
      turn: assistant_turns(:created),
      resources: [],
      tools: [ "list_vulnerabilities", "get_vulnerability" ]
    )
  end

  def headers(grant)
    { "Authorization" => "Bearer #{@service_token}", "X-Hunter-Turn-Grant" => grant }
  end
end
