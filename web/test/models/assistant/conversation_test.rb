require "test_helper"

class Assistant::ConversationTest < ActiveSupport::TestCase
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
