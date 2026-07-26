require "test_helper"

class Api::V1::Assistant::Machine::AuthorizationTest < ActionDispatch::IntegrationTest
  setup do
    @original_enabled = ENV["ASSISTANT_ENABLED"]
    ENV["ASSISTANT_ENABLED"] = "true"
    Assistant::Setting.instance.enable!
    @identity, @raw_service_token = Assistant::ServiceIdentity.generate!(
      name: "machine-#{SecureRandom.hex(4)}", role: "mcp_reader"
    )
  end

  teardown do
    ENV["ASSISTANT_ENABLED"] = @original_enabled
  end

  test "service identity without a turn grant cannot read context" do
    get "/api/v1/assistant/machine/contexts/target/abc", headers: service_headers

    assert_response :forbidden
    assert_equal "invalid_turn_grant", response.parsed_body["error"]
    assert_equal "no-store", response.headers["Cache-Control"]
  end

  test "turn grant without a service identity is rejected" do
    get "/api/v1/assistant/machine/contexts/target/abc",
      headers: { "X-Hunter-Turn-Grant" => raw_grant }

    assert_response :unauthorized
    assert_equal "invalid_service_token", response.parsed_body["error"]
  end

  test "ordinary API tokens sessions and wrong service roles are rejected" do
    _api_token, raw_api_token = ApiToken.generate(user: users(:one), name: "ordinary")
    get "/api/v1/assistant/machine/grant", headers: {
      "Authorization" => "Bearer #{raw_api_token}",
      "X-Hunter-Turn-Grant" => raw_grant
    }
    assert_response :unauthorized

    sign_in_as(users(:one))
    get "/api/v1/assistant/machine/grant", headers: {
      "X-Hunter-Turn-Grant" => raw_grant
    }
    assert_response :unauthorized
    sign_out

    @identity.update_column(:role, "gateway")
    get "/api/v1/assistant/machine/grant", headers: machine_headers
    assert_response :unauthorized
  end

  test "expired grant is rejected before a tool action" do
    grant_token = raw_grant
    Assistant::TurnGrant.order(:id).last.update_column(:expires_at, 1.second.ago)

    get "/api/v1/assistant/machine/contexts/target/abc",
      headers: machine_headers(grant: grant_token)

    assert_response :forbidden
    assert_equal "grant_expired", response.parsed_body["reason"]
  end

  test "MCP service token cannot authenticate an ordinary module route" do
    get "/api/v1/vulnerabilities", headers: {
      "Authorization" => "Bearer #{@raw_service_token}"
    }

    assert_response :unauthorized
  end

  test "machine writes reject oversized request bodies" do
    post "/api/v1/assistant/machine/validations/whiterabbit_template",
      params: { draft: "x" * 70_000 }, headers: machine_headers, as: :json

    assert_response :content_too_large
    assert_equal "request_too_large", response.parsed_body["error"]
  end

  private

  def raw_grant
    @raw_grant ||= Assistant::Grants::Issuer.call(
      turn: assistant_turns(:created),
      resources: [ { type: "target", id: "abc" } ],
      tools: [ "get_selected_context", "validate_whiterabbit_draft" ]
    )
  end

  def service_headers
    { "Authorization" => "Bearer #{@raw_service_token}" }
  end

  def machine_headers(grant: raw_grant)
    service_headers.merge("X-Hunter-Turn-Grant" => grant)
  end
end
