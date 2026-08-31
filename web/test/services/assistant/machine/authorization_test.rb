require "test_helper"

class Assistant::Machine::AuthorizationTest < ActiveSupport::TestCase
  setup do
    @original_admin_username = ENV["ADMIN_USERNAME"]
    ENV["ADMIN_USERNAME"] = "  #{users(:one).username.upcase}  "
    @identity = Assistant::ServiceIdentity.create!(
      name: "authorization-test-mcp",
      role: Assistant::ServiceIdentity::ROLE_MCP_READER,
      token_digest: Assistant::ServiceIdentity.digest("s" * 48)
    )
  end

  teardown do
    ENV["ADMIN_USERNAME"] = @original_admin_username
  end

  test "token-only authorization resolves only the normalized configured administrator" do
    authorization = Assistant::Machine::Authorization.token_only!(service_identity: @identity)

    assert_equal users(:one), authorization.user
    assert_nil authorization.grant
    assert_nil authorization.conversation_id
    assert_nil authorization.turn_id
    assert_nil authorization.provider_profile_id
    assert_equal "token_only", authorization.authorization_mode
    assert_predicate authorization, :token_only?
    assert_match(/\A[0-9a-f-]{36}\z/, authorization.correlation_id)
  end

  test "token-only authorization fails closed when the configured administrator is absent" do
    ENV["ADMIN_USERNAME"] = "missing-administrator"

    error = assert_raises(Assistant::MachineAuthenticator::Error) do
      Assistant::Machine::Authorization.token_only!(service_identity: @identity)
    end

    assert_equal "invalid_machine_principal", error.code
    refute_includes error.message, "missing-administrator"
  end

  test "token-only subject digest is stable and derived from stored identity material" do
    first = Assistant::Machine::Authorization.token_only!(service_identity: @identity)
    second = Assistant::Machine::Authorization.token_only!(service_identity: @identity)

    assert_equal first.subject_digest, second.subject_digest
    assert_match(/\A[0-9a-f]{64}\z/, first.subject_digest)
    refute_includes first.subject_digest, "s" * 48
  end

  test "turn-grant authorization retains existing bindings" do
    raw_grant = Assistant::Grants::Issuer.call(
      turn: assistant_turns(:created), resources: [], tools: [ "get_authoring_policy" ]
    )

    authorization = Assistant::Machine::Authorization.turn_grant!(
      service_identity: @identity,
      raw_grant: raw_grant
    )

    grant = Assistant::TurnGrant.order(:id).last
    assert_equal grant, authorization.grant
    assert_equal grant.user, authorization.user
    assert_equal grant.conversation_id, authorization.conversation_id
    assert_equal grant.turn_id, authorization.turn_id
    assert_equal grant.provider_profile_id, authorization.provider_profile_id
    assert_equal grant.turn.correlation_id, authorization.correlation_id
    assert_equal "turn_grant", authorization.authorization_mode
    refute_predicate authorization, :token_only?
    assert_match(/\A[0-9a-f]{64}\z/, authorization.subject_digest)
  end

  test "audit attributes expose only safe identity metadata" do
    authorization = Assistant::Machine::Authorization.token_only!(service_identity: @identity)

    assert_equal(
      {
        correlation_id: authorization.correlation_id,
        user_id: users(:one).id,
        metadata: {
          authorization_mode: "token_only",
          authorization_subject_digest: authorization.subject_digest
        }
      },
      authorization.audit_attributes
    )
  end
end
