require "test_helper"

# Task 10: a turn on the Claude Code profile is dispatched to ClaudeCodeClient
# (no grant, no gateway envelope, no activation gate) and completes.
class Assistant::ClaudeCodeDispatchTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @profile = assistant_provider_profiles(:claude_code)
  end

  test "a Claude Code turn dispatches to ClaudeCodeClient and completes with an assistant message" do
    ActiveJob::Base.queue_adapter = :inline
    conv = Assistant::Conversation.start!(user: @user, provider_profile: @profile)

    captured = {}
    fake = lambda do |turn:, prompt:|
      captured[:prompt] = prompt
      captured[:turn] = turn
      [
        { "schema_version" => 1, "event_id" => SecureRandom.uuid, "correlation_id" => turn.correlation_id,
          "turn_id" => turn.id, "provider_profile_id" => turn.provider_profile_id,
          "kind" => "assistant_message", "data" => { "body" => "Hello!" } },
        { "schema_version" => 1, "event_id" => SecureRandom.uuid, "correlation_id" => turn.correlation_id,
          "turn_id" => turn.id, "provider_profile_id" => turn.provider_profile_id,
          "kind" => "completed", "data" => { "input_tokens" => 0, "output_tokens" => 0, "tool_call_count" => 0 } },
      ]
    end

    stub_methods(Assistant::ClaudeCodeClient, run_turn: fake) do
      turn = Assistant::TurnCreator.call(conversation: conv, user: @user, body: "hi there", context_refs: [])
      assert_equal "completed", turn.reload.status
      assert_nil turn.error_code
    end

    assert_equal "hi there", captured[:prompt]
    reply = conv.messages.where(role: "assistant").order(:id).last
    assert_equal "Hello!", reply.body
    # No grant is issued for the Claude Code path.
    assert_equal 0, Assistant::TurnGrant.where(turn_id: conv.turns.pluck(:id)).count
  ensure
    ActiveJob::Base.queue_adapter = :test
  end

  test "verify_dispatch does not gate the Claude Code path on activation" do
    # With no provider API keys, Config.enabled? is false; a Claude Code turn must
    # still dispatch (fails loudly later if the backend is down, not here).
    ActiveJob::Base.queue_adapter = :inline
    conv = Assistant::Conversation.start!(user: @user, provider_profile: @profile)
    stub_methods(Assistant::Config, enabled?: false) do
      stub_methods(Assistant::ClaudeCodeClient,
        run_turn: ->(turn:, prompt:) { [ { "schema_version" => 1, "event_id" => SecureRandom.uuid,
          "correlation_id" => turn.correlation_id, "turn_id" => turn.id,
          "provider_profile_id" => turn.provider_profile_id, "kind" => "error",
          "data" => { "code" => "claude_not_configured" } } ] }) do
        turn = Assistant::TurnCreator.call(conversation: conv, user: @user, body: "hi", context_refs: [])
        assert_equal "failed", turn.reload.status
        assert_equal "claude_not_configured", turn.error_code
      end
    end
  ensure
    ActiveJob::Base.queue_adapter = :test
  end
end
