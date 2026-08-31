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
    fake = lambda do |turn:, prompt:|
      calls += 1
      captured[:prompt] = prompt
      captured[:turn] = turn
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
    assert_not_nil captured.fetch(:turn).turn_grant
  end

  test "a Codex client exception fails the turn with a closed code and revokes its grant" do
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

    sensitive = "invalid endpoint contained secret prompt canary and raw grant canary"
    escaped = nil
    stub_methods(Assistant::CodexClient,
      run_turn: ->(**) { raise URI::InvalidURIError, sensitive }) do
      begin
        Assistant::TurnJob.new.perform(
          turn_id: turn.id,
          backend: "codex",
          prompt: "secret prompt canary"
        )
      rescue StandardError => error
        escaped = error
      end
    end

    assert_equal "failed", turn.reload.status
    assert_equal "codex_error", turn.error_code
    refute_nil grant.reload.revoked_at
    assert_nil escaped
    refute_includes turn.error_code, sensitive
    refute_includes turn.error_code, "secret prompt canary"
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
