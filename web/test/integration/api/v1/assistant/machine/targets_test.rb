require "test_helper"

class Api::V1::Assistant::Machine::TargetsTest < ActionDispatch::IntegrationTest
  setup do
    @original_config_enabled = Assistant::Config.method(:enabled?)
    Assistant::Config.define_singleton_method(:enabled?) { |*, **| true }
    Assistant::Setting.instance.enable!
    _identity, @service_token = Assistant::ServiceIdentity.generate!(
      name: "targets-#{SecureRandom.hex(4)}", role: "mcp_reader"
    )
  end

  teardown do
    Assistant::Config.define_singleton_method(:enabled?, @original_config_enabled)
  end

  test "list_targets returns a bounded projection and count" do
    doc = {
      "id" => "t1",
      "target" => { "host" => "a.example.com" },
      "http" => { "status_code" => 200, "title" => "Home" },
      "metadata" => { "program" => "acme" }
    }

    stub_methods(Targets::MongoSource, all: [ doc ], count: 1) do
      get "/api/v1/assistant/machine/targets", params: { q: "example.com" }, headers: headers(read_grant)
    end

    assert_response :success
    body = response.parsed_body
    assert_equal 1, body["count"]
    item = body["items"].first
    assert_equal %w[id host program status_code title], item.keys
    assert_equal "a.example.com", item["host"]
    assert_equal "acme", item["program"]
    refute_includes response.body, "fingerprint"
  end

  test "all projected strings cross the central sanitizer" do
    doc = {
      "id" => "t1",
      "target" => { "host" => "a.example.com" },
      "http" => { "status_code" => 200, "title" => "curl -H 'Cookie: session=do-not-return'" },
      "metadata" => { "program" => "acme" }
    }

    stub_methods(Targets::MongoSource, all: [ doc ], count: 1) do
      get "/api/v1/assistant/machine/targets", headers: headers(read_grant)
    end

    assert_response :success
    assert_includes response.parsed_body.dig("items", 0, "title"), "[REDACTED]"
    refute_includes response.body, "do-not-return"
  end

  test "the final read gate rejects any residual secret and releases its reservation" do
    grant = read_grant
    grant_record = Assistant::TurnGrant.order(:id).last
    unsafe = Assistant::Machine::SensitiveData::Result.new(
      value: { "items" => [ { "title" => "Cookie: session=residual-secret" } ] }, redacted: false
    )

    stub_methods(Targets::MongoSource, all: [], count: 0) do
      stub_methods(Assistant::Machine::SensitiveData, payload: ->(*) { unsafe }) do
        get "/api/v1/assistant/machine/targets", headers: headers(grant)
      end
    end

    assert_response :forbidden
    assert_equal "result_rejected", response.parsed_body["error"]
    assert_equal 0, grant_record.reload.reserved_bytes
  end

  test "list_targets is refused without the targets scope" do
    grant = read_grant
    Assistant::TurnGrant.order(:id).last.update_column(:read_scopes, [])

    get "/api/v1/assistant/machine/targets", headers: headers(grant)

    assert_response :forbidden
    assert_equal "scope_not_allowed", response.parsed_body["reason"]
  end

  test "get_target returns the full projection" do
    doc = {
      "id" => "t1",
      "target" => { "input" => "a.example.com", "host" => "a.example.com", "url" => "https://a.example.com/admin", "scheme" => "https", "port" => 443, "ip" => "192.0.2.4", "path" => "/admin", "method" => "GET" },
      "http" => { "status_code" => 200, "title" => "Home", "webserver" => "nginx", "content_type" => "text/html", "content_length" => 42, "words" => 5, "lines" => 2, "response_time" => "120ms" },
      "metadata" => { "program" => "acme", "tool" => "httpx", "failed" => false, "scan_id" => "never-return" },
      "headers" => { "Server" => "nginx", "Set-Cookie" => "session=do-not-return" },
      "csp" => { "fqdn" => [ "cdn.example.com" ], "domains" => [ "example.com" ] },
      "fingerprint" => { "page_type" => "login", "phash" => 123 }
    }

    stub_methods(Targets::MongoSource, find: doc) do
      get "/api/v1/assistant/machine/targets/t1", headers: headers(read_grant)
    end

    assert_response :success
    target = response.parsed_body["target"]
    assert_equal "https://a.example.com/admin", target["url"]
    assert_equal "login", target["page_type"]
    assert_equal "2xx", target["status_family"]
    assert_equal "GET", target["method"]
    assert_equal "httpx", target["tool"]
    assert_equal [ "cdn.example.com" ], target["csp_fqdns"]
    assert_equal true, target["response_headers"].last["redacted"]
    refute_includes response.body, "do-not-return"
    refute_includes response.body, "never-return"
  end

  test "get_target releases the reservation on a miss" do
    stub_methods(Targets::MongoSource, find: nil) do
      get "/api/v1/assistant/machine/targets/missing", headers: headers(read_grant)
    end

    assert_response :not_found
    assert_equal 0, Assistant::TurnGrant.order(:id).last.reload.reserved_bytes
  end

  private

  def read_grant
    Assistant::Grants::Issuer.call(
      turn: assistant_turns(:created),
      resources: [],
      tools: [ "list_targets", "get_target" ]
    )
  end

  def headers(grant)
    { "Authorization" => "Bearer #{@service_token}", "X-Hunter-Turn-Grant" => grant }
  end
end
