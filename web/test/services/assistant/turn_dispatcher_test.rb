require "test_helper"

class Assistant::TurnDispatcherTest < ActiveSupport::TestCase
  setup do
    @turn = assistant_turns(:created)
    @turn.conversation.messages.create!(
      turn: @turn, role: "user", body: "draft a safe probe", sequence: 1
    )
    @raw_grant = Assistant::Grants::Issuer.call(
      turn: @turn,
      resources: [ { type: "program", id: "bugcrowd-acme" } ],
      tools: [ "get_selected_context" ]
    )
  end

  test "builds the turn envelope, claims the turn, and excludes all service credentials" do
    body = Assistant::TurnDispatcher.call(turn: @turn, raw_grant: @raw_grant)

    assert_equal 1, body["schema_version"]
    assert_equal @turn.correlation_id, body["correlation_id"]
    assert_equal "draft a safe probe", body["user_message"]
    assert_equal @raw_grant, body["turn_grant"]
    assert_equal "queued", @turn.reload.status
    assert_not_nil @turn.queued_at
    refute_includes body.to_json, "provider_api_key"
    refute_includes body.to_json, "mcp_service_token"
  end

  # TurnDispatcher deliberately no longer enqueues anything itself — see the
  # module comment. This guards against silently reintroducing an enqueue
  # here, which would run inside whatever transaction the caller (currently
  # TurnCreator#dispatch) still has open, defeating the whole point of moving
  # the enqueue to after that transaction commits.
  test "does not enqueue the turn job itself" do
    calls = 0
    stub_methods(Assistant::TurnJob, perform_later: ->(**) { calls += 1 }) do
      Assistant::TurnDispatcher.call(turn: @turn, raw_grant: @raw_grant)
    end

    assert_equal 0, calls
  end

  test "a grant that does not match the turn leaves the turn undispatched" do
    assert_raises(ArgumentError) do
      Assistant::TurnDispatcher.call(turn: @turn, raw_grant: "not-the-grant")
    end

    assert_equal "created", @turn.reload.status
    assert_nil @turn.queued_at
  end

  test "a turn that is not created cannot be dispatched again" do
    Assistant::TurnDispatcher.call(turn: @turn, raw_grant: @raw_grant)

    assert_raises(ArgumentError) do
      Assistant::TurnDispatcher.call(turn: @turn, raw_grant: @raw_grant)
    end
  end
end
