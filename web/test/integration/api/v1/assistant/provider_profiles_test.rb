require "test_helper"

class Api::V1::Assistant::ProviderProfilesTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:one)
    @original_admin_username = ENV["ADMIN_USERNAME"]
    ENV["ADMIN_USERNAME"] = @admin.username
    sign_in_as(@admin)
  end

  teardown do
    ENV["ADMIN_USERNAME"] = @original_admin_username
  end

  test "profile responses expose approved metadata but no endpoint or secret reference" do
    get "/api/v1/assistant/provider_profiles"

    assert_response :success
    body = response.parsed_body
    assert_equal Assistant::ProviderProfile.count, body.fetch("provider_profiles").length
    refute_includes response.body, "secret_ref"
    refute_includes response.body, "base_url"
    refute_includes response.body, "headers"
  end

  test "create accepts only catalog-backed metadata" do
    Assistant::ProviderProfile.find_by!(catalog_slug: "anthropic_primary").destroy!

    post "/api/v1/assistant/provider_profiles", params: {
      provider_profile: {
        name: "Reviewed Claude",
        catalog_slug: "anthropic_primary",
        enabled: true,
        tool_call_limit: 4,
        retention_posture: "standard",
        reviewed_at: Time.current.iso8601,
        base_url: "http://169.254.169.254/latest/meta-data",
        headers: { "Authorization" => "secret" }
      }
    }, as: :json

    assert_response :created
    profile = Assistant::ProviderProfile.find_by!(name: "Reviewed Claude")
    assert_equal "anthropic", profile.provider
    assert_equal "claude-sonnet-5", profile.model
    refute_includes response.body, "169.254.169.254"
    refute_includes response.body, "secret"
  end

  test "an enabled profile must have an explicit review timestamp" do
    Assistant::ProviderProfile.find_by!(catalog_slug: "anthropic_primary").destroy!

    post "/api/v1/assistant/provider_profiles", params: {
      provider_profile: {
        name: "Unreviewed",
        catalog_slug: "anthropic_primary",
        enabled: true,
        tool_call_limit: 4,
        retention_posture: "standard"
      }
    }, as: :json

    assert_response :unprocessable_entity
    assert_includes response.parsed_body.fetch("errors").fetch("reviewed_at"),
      "must be present when enabled"
  end

  test "settings update enforces bounds and records the disabling administrator" do
    Assistant::Setting.instance.enable!
    Assistant::Grants::Issuer.call(
      turn: assistant_turns(:created), resources: [], tools: [ "get_authoring_policy" ]
    )
    Assistant::ServiceIdentity.generate!(name: "settings-mcp", role: "mcp_reader")

    patch "/api/v1/assistant/settings", params: {
      settings: {
        assistant_enabled: false,
        transcript_retention_days: 5,
        audit_retention_days: 60
      }
    }, as: :json

    assert_response :success
    setting = Assistant::Setting.instance.reload
    assert_equal 5, setting.transcript_retention_days
    assert_equal 60, setting.audit_retention_days
    assert_equal @admin, setting.disabled_by
    assert Assistant::TurnGrant.where(revoked_at: nil).none?
    assert Assistant::ServiceIdentity.where(enabled: true).none?
    assert_equal "interrupted", assistant_turns(:created).reload.status

    patch "/api/v1/assistant/settings", params: {
      settings: { transcript_retention_days: 31 }
    }, as: :json
    assert_response :unprocessable_entity
  end

  test "kill-switch re-enable requires a newly enabled service identity" do
    Assistant::Setting.instance.enable!
    Assistant::ServiceIdentity.generate!(name: "old-mcp", role: "mcp_reader")
    Assistant::KillSwitch.disable!(user: @admin)

    patch "/api/v1/assistant/settings", params: {
      settings: { assistant_enabled: true, transcript_retention_days: 12 }
    }, as: :json

    assert_response :unprocessable_entity
    assert_equal "assistant_service_identity_required", response.parsed_body.fetch("error")
    refute Assistant::Setting.instance.reload.assistant_enabled?
    refute_equal 12, Assistant::Setting.instance.transcript_retention_days

    Assistant::ServiceIdentity.generate!(name: "new-mcp", role: "mcp_reader")
    patch "/api/v1/assistant/settings", params: {
      settings: { assistant_enabled: true }
    }, as: :json

    assert_response :success
    assert Assistant::Setting.instance.reload.assistant_enabled?
    assert Assistant::TurnGrant.where(revoked_at: nil).none?
    assert_equal "interrupted", assistant_turns(:created).reload.status
  end

  test "settings serialize and audit the independently revocable Control Center authoring switch" do
    Assistant::Setting.instance.enable_control_center_write!

    get "/api/v1/assistant/settings"
    assert_response :success
    assert_equal true, response.parsed_body.fetch("control_center_write_enabled")

    patch "/api/v1/assistant/settings", params: {
      settings: { control_center_write_enabled: false }
    }, as: :json
    assert_response :success
    assert_equal false, response.parsed_body.fetch("control_center_write_enabled")
    refute Assistant::Setting.instance.reload.control_center_write_enabled?
    event = Assistant::AuditEvent.order(:id).last
    assert_equal "control_center_write.disabled", event.event
    assert_equal @admin.id, event.user_id
  end

  test "settings serialize and audit the independently revocable conversation management switch" do
    setting = Assistant::Setting.instance
    setting.enable_conversation_management!(user: @admin)

    get "/api/v1/assistant/settings"
    assert_response :success
    assert_equal true, response.parsed_body.fetch("conversation_management_enabled")

    patch "/api/v1/assistant/settings", params: {
      settings: { conversation_management_enabled: false }
    }, as: :json
    assert_response :success
    assert_equal false, response.parsed_body.fetch("conversation_management_enabled")
    refute setting.reload.conversation_management_enabled?
    event = Assistant::AuditEvent.order(:id).last
    assert_equal "conversation_management.disabled", event.event
    assert_equal @admin.id, event.user_id
  end

  test "settings narrow operational access by exact reviewed tool effect and module" do
    setting = Assistant::Setting.instance
    setting.update!(
      operational_access_enabled: true,
      disabled_capability_tools: [], disabled_capability_effects: [], disabled_capability_modules: []
    )

    patch "/api/v1/assistant/settings", params: {
      settings: {
        operational_access_enabled: false,
        disabled_capability_tools: [ "submit_whiterabbit_job" ],
        disabled_capability_effects: [ "export" ],
        disabled_capability_modules: [ "cves" ]
      }
    }, as: :json

    assert_response :success
    body = response.parsed_body
    assert_equal false, body.fetch("operational_access_enabled")
    assert_equal [ "submit_whiterabbit_job" ], body.fetch("disabled_capability_tools")
    assert_equal [ "export" ], body.fetch("disabled_capability_effects")
    assert_equal [ "cves" ], body.fetch("disabled_capability_modules")
    refute setting.reload.operational_access_enabled?
    assert_equal "capability_policy.updated", Assistant::AuditEvent.order(:id).last.event

    patch "/api/v1/assistant/settings", params: {
      settings: { disabled_capability_tools: [ "unknown_tool" ] }
    }, as: :json
    assert_response :unprocessable_entity
  end
end
