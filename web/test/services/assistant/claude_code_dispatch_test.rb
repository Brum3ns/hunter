require "test_helper"

# Task 10: a turn on the Claude Code profile is dispatched to ClaudeCodeClient
# (no context resolution or gateway envelope) and completes. Legacy stored
# grants remain for confirmation/validation flows but are never transported.
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
    fake = lambda do |turn:, prompt:|
      captured[:prompt] = prompt
      captured[:turn] = turn
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
    grants = Assistant::TurnGrant.where(turn_id: conv.turns.pluck(:id))
    assert_equal 1, grants.count
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

  test "a Claude Code client exception fails the turn with a closed code and revokes its grant" do
    previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    conversation = Assistant::Conversation.start!(user: @user, provider_profile: @profile)
    turn = nil

    stub_methods(Assistant::Config, enabled?: true) do
      turn = Assistant::TurnCreator.call(
        conversation: conversation,
        user: @user,
        body: "secret prompt canary",
        context_refs: []
      )
    end
    grant = turn.turn_grant
    assert_equal "queued", turn.status
    assert_nil grant.revoked_at

    sensitive = "persistence failed with session secret and raw grant canary"
    escaped = nil
    stub_methods(Assistant::ClaudeCodeClient,
      run_turn: ->(**) { raise ActiveRecord::RecordNotSaved, sensitive }) do
      begin
        Assistant::TurnJob.new.perform(
          turn_id: turn.id,
          backend: "claude_code",
          prompt: "secret prompt canary"
        )
      rescue StandardError => error
        escaped = error
      end
    end

    assert_equal "failed", turn.reload.status
    assert_equal "claude_error", turn.error_code
    refute_nil grant.reload.revoked_at
    assert_nil escaped
    refute_includes turn.error_code, sensitive
    refute_includes turn.error_code, "secret prompt canary"
  ensure
    ActiveJob::Base.queue_adapter = previous_adapter
  end
end
