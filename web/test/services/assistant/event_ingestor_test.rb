require "test_helper"

class Assistant::EventIngestorTest < ActiveSupport::TestCase
  setup do
    @turn = assistant_turns(:created)
    @grant_token = Assistant::Grants::Issuer.call(
      turn: @turn, resources: [], tools: [ "get_authoring_policy" ]
    )
  end

  test "assistant message events store encrypted content and are idempotent" do
    payload = event("assistant_message", "body" => "private assistant response")

    assert_equal :accepted, Assistant::EventIngestor.call(payload)
    assert_equal :duplicate, Assistant::EventIngestor.call(payload)
    message = Assistant::Message.order(:id).last
    raw = ActiveRecord::Base.connection.select_value(
      "SELECT body FROM assistant_messages WHERE id = #{message.id.to_i}"
    )
    refute_includes raw, "private assistant response"
    assert_equal "private assistant response", message.body
    assert_equal 1, Assistant::Message.where(turn: @turn, role: "assistant").count
    refute_includes Assistant::AuditEvent.order(:id).last.attributes.to_json, "private assistant response"
  end

  test "draft events store encrypted source with exact turn binding" do
    payload = event("draft", {
      "artifact_type" => "whiterabbit_template",
      "name" => "Probe",
      "content" => "commands: []",
      "validation_details" => {},
      "validation_status" => "pending",
      "validation_version" => "v1"
    })

    assert_difference -> { Assistant::Draft.count }, 1 do
      Assistant::EventIngestor.call(payload)
    end
    draft = Assistant::Draft.order(:id).last
    assert_equal @turn.id, draft.turn_id
    raw = ActiveRecord::Base.connection.select_value(
      "SELECT content FROM assistant_drafts WHERE id = #{draft.id.to_i}"
    )
    refute_includes raw, "commands"
  end

  test "terminal events revoke grants and terminal replay fails closed" do
    assert_equal :accepted, Assistant::EventIngestor.call(
      event("completed", "input_tokens" => 12, "output_tokens" => 8, "tool_call_count" => 1)
    )

    assert_equal "completed", @turn.reload.status
    assert_equal 12, @turn.input_tokens
    assert_not_nil Assistant::TurnGrant.find_by!(turn: @turn).revoked_at
    assert_raises(Assistant::EventIngestor::InvalidEvent) do
      Assistant::EventIngestor.call(event("progress", "status" => "running"))
    end
  end

  test "correlation and profile mismatches are rejected before persistence" do
    bad = event("assistant_message", "body" => "must not persist")
    bad["correlation_id"] = SecureRandom.uuid

    assert_no_difference -> { Assistant::Message.count } do
      error = assert_raises(Assistant::EventIngestor::InvalidEvent) do
        Assistant::EventIngestor.call(bad)
      end
      assert_equal "binding_mismatch", error.code
    end
  end

  private

  def event(kind, data)
    {
      "schema_version" => 1,
      "event_id" => SecureRandom.uuid,
      "correlation_id" => @turn.correlation_id,
      "turn_id" => @turn.id,
      "provider_profile_id" => @turn.provider_profile_id,
      "kind" => kind,
      "data" => data
    }
  end
end
