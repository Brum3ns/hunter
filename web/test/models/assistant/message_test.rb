require "test_helper"

class Assistant::MessageTest < ActiveSupport::TestCase
  test "message encryption is non-deterministic" do
    conversation = assistant_conversations(:one)
    turn = assistant_turns(:created)
    first = conversation.messages.create!(
      turn: turn, role: "assistant", body: "same secret body", sequence: 1
    )
    second = conversation.messages.create!(
      turn: turn, role: "assistant", body: "same secret body", sequence: 2
    )

    rows = ActiveRecord::Base.connection.select_values(
      "SELECT body FROM assistant_messages WHERE id IN (#{first.id.to_i}, #{second.id.to_i}) ORDER BY id"
    )
    assert_equal 2, rows.uniq.length
    rows.each { |body| refute_includes body, "same secret body" }
  end

  test "roles and message size are bounded" do
    message = Assistant::Message.new(
      conversation: assistant_conversations(:one),
      turn: assistant_turns(:created),
      role: "tool",
      body: "x" * 65_537,
      sequence: 1
    )

    refute message.valid?
    assert_includes message.errors[:role], "is not included in the list"
    assert_includes message.errors[:body], "is too long (maximum is 65536 characters)"
  end

  test "turn must belong to the same conversation" do
    message = Assistant::Message.new(
      conversation: assistant_conversations(:one),
      turn: assistant_turns(:other_user),
      role: "assistant",
      body: "response",
      sequence: 1
    )

    refute message.valid?
    assert_includes message.errors[:turn], "must belong to the conversation"
  end
end
