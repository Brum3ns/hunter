require "test_helper"

class Assistant::ConversationTest < ActiveSupport::TestCase
  test "history order prefers saved positions and leaves legacy rows deterministic" do
    first = assistant_conversations(:one)
    second = Assistant::Conversation.create!(
      user: first.user,
      provider_profile: first.provider_profile,
      status: "active",
      title: "Second",
      expires_at: 6.days.from_now,
      history_position: -1
    )

    assert_equal [ second.id, first.id ],
      first.user.assistant_conversations.history_ordered.pluck(:id)
  end

  test "start places a new conversation before the current saved minimum" do
    user = users(:one)
    assistant_conversations(:one).update_column(:history_position, 8)

    conversation = Assistant::Conversation.start!(
      user: user, provider_profile: assistant_provider_profiles(:openai)
    )

    assert_equal 7, conversation.history_position
    assert_equal conversation.id, user.assistant_conversations.history_ordered.first.id
  end

  test "rename strips the title and audits no title content" do
    conversation = assistant_conversations(:one)

    conversation.rename_by!(actor: users(:one), title: "  Triage notes  ")

    assert_equal "Triage notes", conversation.reload.title
    event = Assistant::AuditEvent.find_by!(event: "conversation.renamed")
    assert_equal users(:one).id, event.user_id
    assert_equal conversation.id, event.conversation_id
    assert_equal "accepted", event.status
    assert_equal({ "operation" => "conversation_rename", "outcome" => "accepted" }, event.metadata)
    refute_includes event.attributes.to_json, "Triage notes"
  end

  test "rename rejects a foreign actor and leaves the title untouched" do
    conversation = assistant_conversations(:one)

    assert_raises(ActiveRecord::RecordNotFound) do
      conversation.rename_by!(actor: users(:two), title: "Stolen")
    end

    assert_equal "First assistant conversation", conversation.reload.title
    refute Assistant::AuditEvent.exists?(event: "conversation.renamed")
  end

  test "rename applies model validation after stripping" do
    conversation = assistant_conversations(:one)

    assert_raises(ActiveRecord::RecordInvalid) do
      conversation.rename_by!(actor: users(:one), title: "   ")
    end
    assert_raises(ActiveRecord::RecordInvalid) do
      conversation.rename_by!(actor: users(:one), title: "x" * 201)
    end

    assert_equal "First assistant conversation", conversation.reload.title
    refute Assistant::AuditEvent.exists?(event: "conversation.renamed")
  end

  test "start pins an enabled provider profile and bounded expiration" do
    travel_to Time.zone.parse("2026-07-25 12:00:00") do
      conversation = Assistant::Conversation.start!(
        user: users(:one), provider_profile: assistant_provider_profiles(:openai)
      )

      assert_equal users(:one), conversation.user
      assert_equal assistant_provider_profiles(:openai), conversation.provider_profile
      assert_equal "active", conversation.status
      assert_equal 7.days.from_now, conversation.expires_at
    end
  end

  test "start rejects a disabled provider profile" do
    assert_raises(ActiveRecord::RecordInvalid) do
      Assistant::Conversation.start!(
        user: users(:one), provider_profile: assistant_provider_profiles(:anthropic)
      )
    end
  end

  test "conversation pins its profile and encrypts message bodies" do
    conversation = Assistant::Conversation.start!(
      user: users(:one), provider_profile: assistant_provider_profiles(:openai)
    )
    turn = conversation.append_user_turn!(
      body: "draft a probe",
      context_refs: [
        { type: "program", id: "bugcrowd-acme", label: "Acme", serializer_version: "v1" }
      ]
    )

    raw = ActiveRecord::Base.connection.select_value(
      "SELECT body FROM assistant_messages WHERE id = #{turn.user_message.id.to_i}"
    )
    refute_includes raw, "draft a probe"
    assert_equal "draft a probe", turn.user_message.body
    assert_equal conversation.provider_profile_id, turn.provider_profile_id
    assert_equal conversation.user_id, turn.user_id
    assert_equal [ "bugcrowd-acme" ], turn.context_references.pluck(:resource_id)
  end

  test "provider binding cannot be reassigned" do
    conversation = assistant_conversations(:one)

    conversation.provider_profile = assistant_provider_profiles(:anthropic)

    refute conversation.valid?
    assert_includes conversation.errors[:provider_profile], "cannot be changed"
  end

  test "destroy with content hard deletes all body-bearing rows" do
    conversation = assistant_conversations(:one)
    turn = assistant_turns(:created)
    message = conversation.messages.create!(
      turn: turn, role: "assistant", body: "sensitive response", sequence: 1
    )
    draft = conversation.drafts.create!(
      turn: turn,
      artifact_type: "whiterabbit_template",
      name: "Probe",
      content: "commands: []",
      validation_details: { "codes" => [] },
      validation_status: "valid",
      validation_version: "v1"
    )
    context = assistant_context_references(:program)

    assert_difference -> { Assistant::Conversation.count }, -1 do
      conversation.destroy_with_content!
    end

    refute Assistant::Message.exists?(message.id)
    refute Assistant::Draft.exists?(draft.id)
    refute Assistant::ContextReference.exists?(context.id)
    refute Assistant::Turn.exists?(turn.id)
  end
end
