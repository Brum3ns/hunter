require "test_helper"

class Api::V1::Assistant::Machine::CapabilitiesTest < ActionDispatch::IntegrationTest
  setup do
    @original_config_enabled = Assistant::Config.method(:enabled?)
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
  end

  test "lists only the live enabled catalog and reviewed workflow limits" do
    get "/api/v1/assistant/machine/capabilities", headers: headers(grant)

    assert_response :success
    body = response.parsed_body
    assert_equal 1, body.fetch("catalog_version")
    assert_equal assistant_turns(:created).correlation_id, body.fetch("correlation_id")
    assert_equal({
      "calls_per_turn" => 64,
      "calls_hard_ceiling" => 128,
      "result_bytes_per_call" => 1_048_576,
      "result_bytes_per_turn" => 16_777_216,
      "effects_per_turn" => 32,
      "effects_per_hour" => 120,
      "launches_per_turn" => 16,
      "launches_per_hour" => 60
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

  def grant
    Assistant::Grants::Issuer.call(
      turn: assistant_turns(:created), resources: [], tools: [ "list_hunter_capabilities" ]
    )
  end

  def headers(raw_grant)
    {
      "Authorization" => "Bearer #{@service_token}",
      "X-Hunter-Turn-Grant" => raw_grant
    }
  end
end
