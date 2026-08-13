require "test_helper"

class Assistant::CodexDispatchTest < ActiveSupport::TestCase
  setup do
    @previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :inline
    @user = users(:one)
    @profile = assistant_provider_profiles(:codex)
    Assistant::Setting.instance.enable!
  end

  teardown do
    ActiveJob::Base.queue_adapter = @previous_adapter
  end

  test "a Codex turn dispatches exactly once without reaching another backend" do
    conversation = Assistant::Conversation.start!(user: @user, provider_profile: @profile)
    captured = {}
    calls = 0
    fake = lambda do |turn:, prompt:, turn_grant: nil|
      calls += 1
      captured[:prompt] = prompt
      captured[:turn] = turn
      captured[:turn_grant] = turn_grant&.dup
      successful_events(turn, "Hello from Codex")
    end

    stub_methods(Assistant::Config, enabled?: true) do
      stub_methods(Assistant::GatewayClient,
        run_turn: ->(*) { flunk "a direct Codex turn reached the gateway" }) do
        stub_methods(Assistant::ClaudeCodeClient,
          run_turn: ->(**) { flunk "a Codex turn reached Claude Code" }) do
          stub_methods(Assistant::CodexClient, run_turn: fake) do
            turn = Assistant::TurnCreator.call(
              conversation: conversation,
              user: @user,
              body: "hi codex",
              context_refs: []
            )

            assert_equal "completed", turn.reload.status
            assert_nil turn.error_code
          end
        end
      end
    end

    assert_equal 1, calls
    assert_equal "hi codex", captured[:prompt]
    assert_equal "Hello from Codex", conversation.messages.where(role: "assistant").sole.body
    grant = captured.fetch(:turn).turn_grant
    assert_equal Assistant::TurnGrant.digest(captured.fetch(:turn_grant)), grant.token_digest
  end

  private

  def successful_events(turn, reply)
    [
      {
        "schema_version" => 1,
        "event_id" => SecureRandom.uuid,
        "correlation_id" => turn.correlation_id,
        "turn_id" => turn.id,
        "provider_profile_id" => turn.provider_profile_id,
        "kind" => "assistant_message",
        "data" => { "body" => reply }
      },
      {
        "schema_version" => 1,
        "event_id" => SecureRandom.uuid,
        "correlation_id" => turn.correlation_id,
        "turn_id" => turn.id,
        "provider_profile_id" => turn.provider_profile_id,
        "kind" => "completed",
        "data" => { "input_tokens" => 0, "output_tokens" => 0, "tool_call_count" => 0 }
      }
    ]
  end
end
