require "test_helper"

class Assistant::ActionReceiptTest < ActiveSupport::TestCase
  setup do
    @original_admin_username = ENV["ADMIN_USERNAME"]
    ENV["ADMIN_USERNAME"] = users(:one).username
    @identity = Assistant::ServiceIdentity.create!(
      name: "receipt-test-mcp",
      role: Assistant::ServiceIdentity::ROLE_MCP_READER,
      token_digest: Assistant::ServiceIdentity.digest("r" * 48)
    )
  end

  teardown do
    ENV["ADMIN_USERNAME"] = @original_admin_username
  end

  test "issues a bounded token-only receipt attributed to the configured human" do
    authorization = token_authorization

    receipt = nil
    assert_difference "Assistant::AuditEvent.count", 1 do
      receipt = issue_receipt(authorization)
    end

    assert_equal %w[
      human_user_id idempotency_digest occurred_at receipt_id replayed status
      target tool turn_id
    ], receipt.keys.sort
    assert_equal users(:one).id, receipt.fetch("human_user_id")
    assert_nil receipt.fetch("turn_id")
    assert_equal({ "type" => "vulnerability", "id" => "VULN-42" }, receipt.fetch("target"))
    refute_includes receipt.to_json, "request-secret-value"

    event = Assistant::AuditEvent.order(:id).last
    assert_equal "machine.action_receipt", event.event
    assert_equal receipt.fetch("receipt_id"), event.metadata.fetch("receipt_id")
    assert_equal "token_only", event.metadata.fetch("authorization_mode")
    assert_equal authorization.subject_digest,
      event.metadata.fetch("authorization_subject_digest")
    assert_equal users(:one).id, event.user_id
    assert_nil event.conversation_id
    assert_nil event.turn_id
    assert_nil event.provider_profile_id
    refute_includes event.to_json, "request-secret-value"
  end

  test "grant-mode receipts retain the positive turn binding" do
    raw = Assistant::Grants::Issuer.call(
      turn: assistant_turns(:created), resources: [], tools: [ "create_vulnerability" ]
    )
    authorization = Assistant::Machine::Authorization.turn_grant!(
      service_identity: @identity, raw_grant: raw
    )

    receipt = issue_receipt(authorization)

    assert_equal assistant_turns(:created).id, receipt.fetch("turn_id")
    assert_equal "turn_grant",
      Assistant::AuditEvent.order(:id).last.metadata.fetch("authorization_mode")
  end

  test "replay follows the stable authorization subject across requests" do
    first_authorization = token_authorization
    issued = issue_receipt(first_authorization)
    second_authorization = token_authorization

    replayed = Assistant::ActionReceipt.replay(
      authorization: second_authorization,
      tool: "create_vulnerability",
      idempotency_key: "request-secret-value"
    )

    assert_equal "idempotent_replay", replayed.fetch("status")
    assert_equal issued.fetch("target"), replayed.fetch("target")
    assert_predicate replayed, :frozen?
  end

  test "a different service identity generation cannot replay an old action" do
    issue_receipt(token_authorization)
    rotated = Assistant::ServiceIdentity.create!(
      name: "receipt-rotated-mcp",
      role: Assistant::ServiceIdentity::ROLE_MCP_READER,
      token_digest: Assistant::ServiceIdentity.digest("n" * 48)
    )
    authorization = Assistant::Machine::Authorization.token_only!(service_identity: rotated)

    assert_nil Assistant::ActionReceipt.replay(
      authorization: authorization,
      tool: "create_vulnerability",
      idempotency_key: "request-secret-value"
    )
  end

  private

  def token_authorization
    Assistant::Machine::Authorization.token_only!(service_identity: @identity)
  end

  def issue_receipt(authorization)
    Assistant::ActionReceipt.issue!(
      authorization: authorization,
      tool: "create_vulnerability",
      status: "created",
      target_type: "vulnerability",
      target_id: "VULN-42",
      idempotency_key: "request-secret-value",
      replayed: false
    )
  end
end
