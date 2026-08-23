require "test_helper"

class Api::V1::Assistant::Machine::CvesTest < ActionDispatch::IntegrationTest
  setup do
    @original_config_enabled = Assistant::Config.method(:enabled?)
    Assistant::Config.define_singleton_method(:enabled?) { |*, **| true }
    Assistant::Setting.instance.enable!
    _identity, @service_token = Assistant::ServiceIdentity.generate!(
      name: "cves-#{SecureRandom.hex(4)}", role: "mcp_reader"
    )
  end

  teardown do
    Assistant::Config.define_singleton_method(:enabled?, @original_config_enabled)
  end

  test "list_cves returns a bounded projection and count" do
    cve = {
      "id" => "CVE-2024-1234",
      "summary" => "Something bad",
      "severity_level" => "high",
      "severity_score" => 7.5,
      "has_fix" => true,
      "modified" => "2026-01-01T00:00:00Z",
      "details" => "a very long body that must not appear in the summary"
    }

    stub_methods(Cves::MongoSource, all: [ cve ], count: 1) do
      get "/api/v1/assistant/machine/cves", params: { q: "bad" }, headers: headers(read_grant)
    end

    assert_response :success
    body = response.parsed_body
    assert_equal 1, body["count"]
    item = body["items"].first
    assert_equal %w[id summary severity_level severity_score has_fix modified], item.keys
    assert_equal "CVE-2024-1234", item["id"]
    assert_equal "high", item["severity_level"]
    refute_includes response.body, "very long body"
  end

  test "list_cves is refused without the cves scope" do
    grant = read_grant
    Assistant::TurnGrant.order(:id).last.update_column(:read_scopes, [])

    get "/api/v1/assistant/machine/cves", headers: headers(grant)

    assert_response :forbidden
    assert_equal "scope_not_granted", response.parsed_body["error"]
  end

  test "get_cve returns the full projection" do
    cve = {
      "id" => "CVE-2024-1234",
      "summary" => "Something bad",
      "severity_level" => "high",
      "severity_score" => 7.5,
      "has_fix" => true,
      "modified" => "2026-01-01T00:00:00Z",
      "details" => "full details",
      "aliases" => [ "GHSA-xxxx-yyyy-zzzz" ],
      "published" => "2024-01-01T00:00:00Z",
      "withdrawn" => nil,
      "cwe_ids" => [ "CWE-79" ],
      "ecosystems" => [ "npm" ],
      "languages" => [ "javascript" ],
      "vendors" => [ "acme" ],
      "tags" => [ "xss" ],
      "affected" => [ { "ecosystem" => "npm", "package" => "foo" } ],
      "references" => [ "https://example.com/advisory" ],
      "chain" => { "fixed_in" => "1.2.3" },
      "osv_id" => "GHSA-xxxx-yyyy-zzzz",
      "first_seen_at" => "2024-01-01T00:00:00Z",
      "last_synced_at" => "2026-01-01T00:00:00Z"
    }

    stub_methods(Cves::MongoSource, find: cve) do
      get "/api/v1/assistant/machine/cves/CVE-2024-1234", headers: headers(read_grant)
    end

    assert_response :success
    result = response.parsed_body["cve"]
    expected_keys = %w[
      id summary severity_level severity_score has_fix modified
      details aliases published withdrawn cwe_ids ecosystems
      languages vendors tags affected references chain
      osv_id first_seen_at last_synced_at
    ]
    assert_equal expected_keys, result.keys
    assert_equal "full details", result["details"]
    assert_equal [ "GHSA-xxxx-yyyy-zzzz" ], result["aliases"]
    assert_equal({ "fixed_in" => "1.2.3" }, result["chain"])
  end

  test "get_cve releases the reservation on a miss" do
    stub_methods(Cves::MongoSource, find: nil) do
      get "/api/v1/assistant/machine/cves/CVE-9999-0000", headers: headers(read_grant)
    end

    assert_response :not_found
    assert_equal 0, Assistant::TurnGrant.order(:id).last.reload.reserved_bytes
  end

  private

  def read_grant
    Assistant::Grants::Issuer.call(
      turn: assistant_turns(:created),
      resources: [],
      tools: [ "list_cves", "get_cve" ]
    )
  end

  def headers(grant)
    { "Authorization" => "Bearer #{@service_token}", "X-Hunter-Turn-Grant" => grant }
  end
end
