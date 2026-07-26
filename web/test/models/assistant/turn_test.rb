require "test_helper"

class Assistant::TurnTest < ActiveSupport::TestCase
  test "supports only the closed lifecycle state set" do
    expected = %w[created queued running completed failed canceled interrupted]

    assert_equal expected, Assistant::Turn::STATUSES
    turn = assistant_turns(:created)
    turn.status = "retrying"
    refute turn.valid?
  end

  test "user and provider bindings must match the conversation" do
    turn = assistant_turns(:created)

    turn.user = users(:two)
    turn.provider_profile = assistant_provider_profiles(:anthropic)

    refute turn.valid?
    assert_includes turn.errors[:user], "must match the conversation"
    assert_includes turn.errors[:provider_profile], "must match the conversation"
  end

  test "correlation and ownership bindings are immutable" do
    turn = assistant_turns(:created)

    turn.correlation_id = SecureRandom.uuid

    refute turn.valid?
    assert_includes turn.errors[:correlation_id], "cannot be changed"
  end
end
