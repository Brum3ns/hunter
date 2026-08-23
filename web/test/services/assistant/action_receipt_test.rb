require "test_helper"

class Assistant::ActionReceiptTest < ActiveSupport::TestCase
  test "issues a bounded receipt attributed to the turn human" do
    raw = Assistant::Grants::Issuer.call(
      turn: assistant_turns(:created),
      resources: [],
      tools: [ "create_vulnerability" ]
    )
    grant = Assistant::TurnGrant.find_by!(token_digest: Assistant::TurnGrant.digest(raw))

    receipt = nil
    assert_difference "Assistant::AuditEvent.count", 1 do
      receipt = Assistant::ActionReceipt.issue!(
        grant: grant,
        tool: "create_vulnerability",
        status: "created",
        target_type: "vulnerability",
        target_id: "VULN-42",
        idempotency_key: "request-secret-value",
        replayed: false
      )
    end

    assert_equal %w[
      human_user_id idempotency_digest occurred_at receipt_id replayed status
      target tool turn_id
    ], receipt.keys.sort
    assert_equal users(:one).id, receipt.fetch("human_user_id")
    assert_equal({ "type" => "vulnerability", "id" => "VULN-42" }, receipt.fetch("target"))
    refute_includes receipt.to_json, "request-secret-value"

    event = Assistant::AuditEvent.order(:id).last
    assert_equal "machine.action_receipt", event.event
    assert_equal receipt.fetch("receipt_id"), event.metadata.fetch("receipt_id")
    refute_includes event.to_json, "request-secret-value"
  end
end
