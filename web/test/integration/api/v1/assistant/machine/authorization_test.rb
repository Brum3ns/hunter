require "test_helper"

class Api::V1::Assistant::Machine::AuthorizationTest < ActionDispatch::IntegrationTest
  setup do
    @original_enabled = ENV["ASSISTANT_ENABLED"]
    @original_admin_username = ENV["ADMIN_USERNAME"]
    @original_config_enabled = Assistant::Config.method(:enabled?)
    ENV["ASSISTANT_ENABLED"] = "true"
    ENV["ADMIN_USERNAME"] = users(:one).username
    Assistant::Config.define_singleton_method(:enabled?) { true }
    Assistant::Setting.instance.enable!
    @identity, @raw_service_token = Assistant::ServiceIdentity.generate!(
      name: "machine-#{SecureRandom.hex(4)}", role: "mcp_reader"
    )
  end

  teardown do
    ENV["ASSISTANT_ENABLED"] = @original_enabled
    ENV["ADMIN_USERNAME"] = @original_admin_username
    Assistant::Config.define_singleton_method(:enabled?, @original_config_enabled)
  end

  test "service identity without a turn grant reaches a reviewed catalog route" do
    get "/api/v1/assistant/machine/capabilities", headers: service_headers

    assert_response :success
    assert_equal "token_only", response.parsed_body.fetch("authorization_mode")
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_nil response.headers["X-Hunter-Grant-Calls-Remaining"]
    assert_nil response.headers["X-Hunter-Grant-Bytes-Remaining"]
  end

  test "turn grant without a service identity is rejected" do
    get "/api/v1/assistant/machine/contexts/target/abc",
      headers: { "X-Hunter-Turn-Grant" => raw_grant }

    assert_response :unauthorized
    assert_equal "invalid_service_token", response.parsed_body["error"]
  end

  test "missing malformed disabled wrong-role ordinary and session credentials are rejected" do
    get "/api/v1/assistant/machine/capabilities"
    assert_response :unauthorized

    get "/api/v1/assistant/machine/capabilities", headers: { "Authorization" => "Basic nope" }
    assert_response :unauthorized

    @identity.update!(enabled: false)
    get "/api/v1/assistant/machine/capabilities", headers: service_headers
    assert_response :unauthorized
    @identity.update_columns(enabled: true, role: "gateway")
    get "/api/v1/assistant/machine/capabilities", headers: service_headers
    assert_response :unauthorized

    _api_token, raw_api_token = ApiToken.generate(user: users(:one), name: "ordinary")
    get "/api/v1/assistant/machine/capabilities",
      headers: { "Authorization" => "Bearer #{raw_api_token}" }
    assert_response :unauthorized

    sign_in_as(users(:one))
    get "/api/v1/assistant/machine/capabilities"
    assert_response :unauthorized
    sign_out
  end

  test "missing configured administrator fails without leaking its username" do
    ENV["ADMIN_USERNAME"] = "missing-machine-administrator"

    get "/api/v1/assistant/machine/capabilities", headers: service_headers

    assert_response :forbidden
    assert_equal "invalid_machine_principal", response.parsed_body.fetch("error")
    refute_includes response.body, "missing-machine-administrator"
  end

  test "legacy workflow routes still require a live turn grant" do
    requests = [
      -> { get "/api/v1/assistant/machine/grant", headers: service_headers },
      -> { get "/api/v1/assistant/machine/contexts/target/abc", headers: service_headers },
      -> { get "/api/v1/assistant/machine/artifacts/whiterabbit_template/1", headers: service_headers },
      -> { get "/api/v1/assistant/machine/policies/whiterabbit_template", headers: service_headers },
      -> {
        post "/api/v1/assistant/machine/validations/whiterabbit_template",
          params: { draft: {} }, headers: service_headers, as: :json
      }
    ]

    requests.each do |perform|
      perform.call
      assert_response :forbidden
      assert_equal "invalid_turn_grant", response.parsed_body.fetch("error")
    end
  end

  test "a turn-grant header cannot switch or narrow a reviewed route" do
    get "/api/v1/assistant/machine/capabilities", headers: service_headers.merge(
      "X-Hunter-Turn-Grant" => "invalid-and-ignored"
    )

    assert_response :success
    assert_equal "token_only", response.parsed_body.fetch("authorization_mode")
  end

  test "expired grant is rejected before a tool action" do
    grant_token = raw_grant
    Assistant::TurnGrant.order(:id).last.update_column(:expires_at, 1.second.ago)

    get "/api/v1/assistant/machine/contexts/target/abc",
      headers: machine_headers(grant: grant_token)

    assert_response :forbidden
    assert_equal "turn_grant_expired", response.parsed_body["error"]
    refute response.parsed_body.key?("reason")
  end

  test "MCP service token cannot authenticate an ordinary module route" do
    get "/api/v1/vulnerabilities", headers: {
      "Authorization" => "Bearer #{@raw_service_token}"
    }

    assert_response :unauthorized
  end

  test "machine writes reject oversized request bodies" do
    assert_equal Assistant::Config.max_result_bytes,
      Api::V1::Assistant::Machine::BaseController::MAX_REQUEST_BYTES

    post "/api/v1/assistant/machine/validations/whiterabbit_template",
      params: { draft: "x" * (Api::V1::Assistant::Machine::BaseController::MAX_REQUEST_BYTES + 1) },
      headers: machine_headers, as: :json

    assert_response :content_too_large
    assert_equal "request_too_large", response.parsed_body["error"]
  end

  test "grant introspection returns the closed read and write scope sets" do
    get "/api/v1/assistant/machine/grant", headers: machine_headers

    assert_response :success
    assert_equal Assistant::TurnGrant::READ_SCOPES, response.parsed_body.fetch("read_scopes")
    assert_equal [], response.parsed_body.fetch("write_scopes")
  end

  private

  def raw_grant
    @raw_grant ||= Assistant::Grants::Issuer.call(
      turn: assistant_turns(:created),
      resources: [ { type: "target", id: "abc" } ],
      tools: [
        "get_selected_context",
        "validate_whiterabbit_draft",
        *Assistant::Grants::Issuer::CHAT_READ_TOOLS
      ]
    )
  end

  def service_headers
    { "Authorization" => "Bearer #{@raw_service_token}" }
  end

  def machine_headers(grant: raw_grant)
    service_headers.merge("X-Hunter-Turn-Grant" => grant)
  end
end
