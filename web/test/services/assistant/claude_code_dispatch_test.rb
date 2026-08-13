require "test_helper"

# Task 10: a turn on the Claude Code profile is dispatched to ClaudeCodeClient
# (no context resolution or gateway envelope) and completes. Path B (task PB2):
# the dispatch now also issues a per-turn grant
# and threads its raw token through to ClaudeCodeClient, so these stubs must
# accept the `turn_grant:` keyword too.
class Assistant::ClaudeCodeDispatchTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @profile = assistant_provider_profiles(:claude_code)
    Assistant::Setting.instance.enable!
  end

  test "a Claude Code turn dispatches to ClaudeCodeClient and completes with an assistant message" do
    ActiveJob::Base.queue_adapter = :inline
    conv = Assistant::Conversation.start!(user: @user, provider_profile: @profile)

    captured = {}
    fake = lambda do |turn:, prompt:, turn_grant: nil|
      captured[:prompt] = prompt
      captured[:turn] = turn
      # Same object as `raw_grant` in TurnCreator, which is `.clear`-ed in its
      # `ensure` right after this synchronous inline job finishes — dup now so
      # the assertion below inspects the real value, not the cleared buffer.
      captured[:turn_grant] = turn_grant&.dup
      [
        { "schema_version" => 1, "event_id" => SecureRandom.uuid, "correlation_id" => turn.correlation_id,
          "turn_id" => turn.id, "provider_profile_id" => turn.provider_profile_id,
          "kind" => "assistant_message", "data" => { "body" => "Hello!" } },
        { "schema_version" => 1, "event_id" => SecureRandom.uuid, "correlation_id" => turn.correlation_id,
          "turn_id" => turn.id, "provider_profile_id" => turn.provider_profile_id,
          "kind" => "completed", "data" => { "input_tokens" => 0, "output_tokens" => 0, "tool_call_count" => 0 } }
      ]
    end

    stub_methods(Assistant::Config, enabled?: true) do
      stub_methods(Assistant::GatewayClient,
        run_turn: ->(*) { flunk "a direct Claude Code turn reached the gateway" }) do
        stub_methods(Assistant::CodexClient,
          run_turn: ->(**) { flunk "a Claude Code turn reached Codex" }) do
          stub_methods(Assistant::ClaudeCodeClient, run_turn: fake) do
            turn = Assistant::TurnCreator.call(
              conversation: conv, user: @user, body: "hi there", context_refs: []
            )
            assert_equal "completed", turn.reload.status
            assert_nil turn.error_code
          end
        end
      end
    end

    assert_equal "hi there", captured[:prompt]
    reply = conv.messages.where(role: "assistant").order(:id).last
    assert_equal "Hello!", reply.body
    # Path B: a grant IS now issued for the Claude Code path, and its raw token
    # (not the digest) is what reaches ClaudeCodeClient.
    grants = Assistant::TurnGrant.where(turn_id: conv.turns.pluck(:id))
    assert_equal 1, grants.count
    refute_nil captured[:turn_grant]
    assert_equal Assistant::TurnGrant.digest(captured[:turn_grant]), grants.sole.token_digest
  ensure
    ActiveJob::Base.queue_adapter = :test
  end

  test "verify_dispatch gates the Claude Code path on activation" do
    conv = Assistant::Conversation.start!(user: @user, provider_profile: @profile)
    called = false
    counts = {
      turns: Assistant::Turn.count,
      messages: Assistant::Message.count,
      grants: Assistant::TurnGrant.count,
      audits: Assistant::AuditEvent.count
    }

    stub_methods(Assistant::Config, enabled?: false) do
      stub_methods(Assistant::ClaudeCodeClient,
        run_turn: ->(**) { called = true }) do
        error = assert_raises(Assistant::TurnCreator::Rejected) do
          Assistant::TurnCreator.call(
            conversation: conv, user: @user, body: "hi", context_refs: []
          )
        end
        assert_equal "assistant_disabled", error.code
      end
    end

    assert_equal counts, {
      turns: Assistant::Turn.count,
      messages: Assistant::Message.count,
      grants: Assistant::TurnGrant.count,
      audits: Assistant::AuditEvent.count
    }
    refute called
  end
end
