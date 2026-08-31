require "test_helper"

class Assistant::Machine::AuthorizerTest < ActiveSupport::TestCase
  setup do
    @original_admin_username = ENV["ADMIN_USERNAME"]
    ENV["ADMIN_USERNAME"] = users(:one).username
    @identity = Assistant::ServiceIdentity.create!(
      name: "authorizer-test-mcp",
      role: Assistant::ServiceIdentity::ROLE_MCP_READER,
      token_digest: Assistant::ServiceIdentity.digest("a" * 48)
    )
    @authorization = Assistant::Machine::Authorization.token_only!(service_identity: @identity)
  end

  teardown do
    ENV["ADMIN_USERNAME"] = @original_admin_username
  end

  test "token-only authorization accepts an enabled catalog tool with its exact scope" do
    reservation = Assistant::Machine::Authorizer.reserve!(
      authorization: @authorization,
      tool: "list_targets",
      scope: "targets_read",
      resource_type: "target",
      resource_id: "any-reviewed-target"
    )

    assert reservation.complete!(bytes: 12)
  end

  test "unknown legacy and mismatched scopes fail closed" do
    assert_authorization_error("scope_not_granted") do
      Assistant::Machine::Authorizer.reserve!(
        authorization: @authorization, tool: "unknown_tool", scope: "targets_read"
      )
    end
    assert_authorization_error("scope_not_granted") do
      Assistant::Machine::Authorizer.reserve!(
        authorization: @authorization, tool: "get_selected_context"
      )
    end
    assert_authorization_error("scope_not_granted") do
      Assistant::Machine::Authorizer.reserve!(
        authorization: @authorization, tool: "list_targets", scope: "programs_read"
      )
    end
  end

  test "live capability policy is checked for every reservation" do
    Assistant::Setting.instance.update!(disabled_capability_tools: [ "list_targets" ])

    assert_authorization_error("capability_disabled") do
      Assistant::Machine::Authorizer.reserve!(
        authorization: @authorization, tool: "list_targets", scope: "targets_read"
      )
    end
  end

  test "token-only completion enforces the per-call byte ceiling and is one-use" do
    reservation = reserve_list_targets

    refute reservation.complete!(bytes: Assistant::Config.max_result_bytes + 1)
    assert_authorization_error("reservation_consumed") { reservation.fail! }
  end

  test "a committed write completion stays successful and audits an oversized response" do
    reservation = reserve_list_targets

    assert reservation.complete_write!(bytes: Assistant::Config.max_result_bytes + 1)
    event = Assistant::AuditEvent.order(:id).last
    assert_equal "machine.result_rejected", event.event
    assert_equal "rejected", event.status
    assert_equal @authorization.subject_digest,
      event.metadata.fetch("authorization_subject_digest")
    assert_equal "token_only", event.metadata.fetch("authorization_mode")
  end

  test "turn-grant mode delegates to the existing grant authorizer" do
    raw_grant = Assistant::Grants::Issuer.call(
      turn: assistant_turns(:created), resources: [], tools: [ "get_authoring_policy" ]
    )
    authorization = Assistant::Machine::Authorization.turn_grant!(
      service_identity: @identity, raw_grant: raw_grant
    )
    sentinel = Object.new
    invocation = nil

    stub_methods(Assistant::Grants::Authorizer, reserve!: ->(**args) { invocation = args; sentinel }) do
      result = Assistant::Machine::Authorizer.reserve!(
        authorization: authorization, tool: "get_authoring_policy"
      )
      assert_same sentinel, result
    end

    assert_equal "get_authoring_policy", invocation.fetch(:tool)
    assert_equal raw_grant, invocation.fetch(:raw_grant)
  end

  private

  def reserve_list_targets
    Assistant::Machine::Authorizer.reserve!(
      authorization: @authorization, tool: "list_targets", scope: "targets_read"
    )
  end

  def assert_authorization_error(code, &block)
    error = assert_raises(Assistant::Grants::AuthorizationError, &block)
    assert_equal code, error.code
  end
end
