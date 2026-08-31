require "test_helper"

class Api::V1::Assistant::Machine::CapabilitiesTest < ActionDispatch::IntegrationTest
  setup do
    @original_config_enabled = Assistant::Config.method(:enabled?)
    @original_admin_username = ENV["ADMIN_USERNAME"]
    ENV["ADMIN_USERNAME"] = users(:one).username
    Assistant::Config.define_singleton_method(:enabled?) { |*, **| true }
    Assistant::Setting.instance.enable!
    Assistant::Setting.instance.update!(
      operational_access_enabled: true,
      disabled_capability_tools: [ "list_targets" ],
      disabled_capability_effects: [],
      disabled_capability_modules: []
    )
    _identity, @service_token = Assistant::ServiceIdentity.generate!(
      name: "capabilities-#{SecureRandom.hex(4)}", role: "mcp_reader"
    )
  end

  teardown do
    Assistant::Config.define_singleton_method(:enabled?, @original_config_enabled)
    ENV["ADMIN_USERNAME"] = @original_admin_username
  end

  test "lists only the live enabled catalog and reviewed workflow limits" do
    get "/api/v1/assistant/machine/capabilities", headers: headers

    assert_response :success
    body = response.parsed_body
    assert_equal 1, body.fetch("catalog_version")
    assert_match(/\A[0-9a-f-]{36}\z/, body.fetch("correlation_id"))
    assert_equal "token_only", body.fetch("authorization_mode")
    assert_equal({
      "calls_per_turn" => nil,
      "calls_hard_ceiling" => nil,
      "result_bytes_per_call" => Assistant::Config.max_result_bytes,
      "result_bytes_per_turn" => nil,
      "effects_per_turn" => nil,
      "effects_per_hour" => Assistant::Config.max_effects_per_hour,
      "launches_per_turn" => nil,
      "launches_per_hour" => Assistant::Config.max_launches_per_hour
    }, body.fetch("limits"))

    names = body.fetch("tools").pluck("name")
    assert_equal 69, names.length
    assert_includes names, "list_hunter_capabilities"
    refute_includes names, "list_targets"
    tool = body.fetch("tools").find { |entry| entry.fetch("name") == "submit_whiterabbit_job" }
    assert_equal %w[effect gate idempotency module name rate_profile scope], tool.keys.sort
    assert_equal "execute", tool.fetch("effect")
    assert_equal "control_center_jobs_submit", tool.fetch("scope")
    refute_includes response.body, "machine_path"
    refute_includes response.body, "api_operation"
    refute_includes response.body, "audit_event"
  end

  private

  def headers(*)
    { "Authorization" => "Bearer #{@service_token}" }
  end
end
