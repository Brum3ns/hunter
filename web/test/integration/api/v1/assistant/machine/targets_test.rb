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
    doc = Target.new(
      "id" => "t1",
      "target" => { "host" => "a.example.com" },
      "http" => { "status_code" => 200, "title" => "Home" },
      "metadata" => { "program" => "acme" }
    )

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

  test "list_targets is refused without the targets scope" do
    grant = read_grant
    Assistant::TurnGrant.order(:id).last.update_column(:read_scopes, [])

    get "/api/v1/assistant/machine/targets", headers: headers(grant)

    assert_response :forbidden
    assert_equal "scope_not_allowed", response.parsed_body["reason"]
  end

  test "get_target returns the full projection" do
    doc = Target.new(
      "id" => "t1",
      "target" => { "host" => "a.example.com", "url" => "https://a.example.com", "scheme" => "https", "port" => 443 },
      "http" => { "status_code" => 200, "title" => "Home", "webserver" => "nginx", "content_type" => "text/html" },
      "metadata" => { "program" => "acme" },
      "fingerprint" => { "page_type" => "login" }
    )

    stub_methods(Targets::MongoSource, find: doc) do
      get "/api/v1/assistant/machine/targets/t1", headers: headers(read_grant)
    end

    assert_response :success
    target = response.parsed_body["target"]
    assert_equal "https://a.example.com", target["url"]
    assert_equal "login", target["page_type"]
    assert_equal "2xx", target["status_family"]
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
