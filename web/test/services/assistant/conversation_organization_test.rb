require "test_helper"

class Assistant::ConversationOrganizationTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @first = assistant_conversations(:one)
    @second = Assistant::Conversation.start!(
      user: @user, provider_profile: assistant_provider_profiles(:openai)
    )
  end

  test "reorder persists an exact owned permutation without changing timestamps" do
    first_updated_at = @first.updated_at
    second_updated_at = @second.updated_at

    result = Assistant::ConversationOrganization.reorder!(
      user: @user, conversation_ids: [ @first.id, @second.id ]
    )

    assert_equal [ @first.id, @second.id ], result.map(&:id)
    assert_equal [ @first.id, @second.id ],
      @user.assistant_conversations.history_ordered.pluck(:id)
    assert_equal first_updated_at, @first.reload.updated_at
    assert_equal second_updated_at, @second.reload.updated_at
    event = Assistant::AuditEvent.find_by!(event: "conversation.reordered")
    assert_equal @user.id, event.user_id
    assert_equal "accepted", event.status
    assert_equal({
      "operation" => "conversation_reorder", "outcome" => "accepted", "count" => 2
    }, event.metadata)
    refute_includes event.attributes.to_json, [ @first.id, @second.id ].to_json
  end

  test "malformed order arrays fail before any mutation" do
    malformed = [
      nil,
      "not-an-array",
      [ @first.id, @first.id ],
      [ @first.id.to_s, @second.id ],
      [ -1, @second.id ],
      (1..1001).to_a
    ]

    malformed.each do |conversation_ids|
      before = persisted_positions
      error = assert_raises(Assistant::ConversationOrganization::InvalidOrder) do
        Assistant::ConversationOrganization.reorder!(
          user: @user, conversation_ids: conversation_ids
        )
      end

      assert_equal "invalid_order", error.code
      assert_equal before, persisted_positions
    end
    refute Assistant::AuditEvent.exists?(event: "conversation.reordered")
  end

  test "stale omitted and foreign permutations fail atomically" do
    foreign_id = assistant_conversations(:other_user).id
    stale_orders = [
      [ @first.id ],
      [ @first.id, @second.id, foreign_id ],
      [ @first.id, foreign_id ]
    ]

    stale_orders.each do |conversation_ids|
      before = persisted_positions
      error = assert_raises(Assistant::ConversationOrganization::InvalidOrder) do
        Assistant::ConversationOrganization.reorder!(
          user: @user, conversation_ids: conversation_ids
        )
      end

      assert_equal "conversation_order_stale", error.code
      assert_equal before, persisted_positions
    end
    refute Assistant::AuditEvent.exists?(event: "conversation.reordered")
  end

  private

  def persisted_positions
    @user.assistant_conversations.order(:id).pluck(:id, :history_position)
  end
end
