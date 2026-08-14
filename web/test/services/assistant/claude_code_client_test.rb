require "test_helper"

class Assistant::ClaudeCodeClientTest < ActiveSupport::TestCase
  def with_env(values)
    originals = values.keys.to_h { |k| [ k, ENV[k] ] }
    values.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    originals.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  setup do
    @turn = assistant_turns(:created)
    @turn.conversation.update!(claude_session_id: nil)
  end

  test "success returns assistant_message + completed and stores the session id" do
    with_env("ASSISTANT_CLAUDE_URL" => "http://assistant-claude:8083") do
      poster = ->(_body) { { "session_id" => "sess_9", "reply" => "Hi!" } }
      events = Assistant::ClaudeCodeClient.run_turn(turn: @turn, prompt: "hello", poster: poster)

      assert_equal %w[assistant_message completed], events.map { |e| e["kind"] }
      assert_equal "Hi!", events.first["data"]["body"]
      assert_equal @turn.correlation_id, events.first["correlation_id"]
      assert_equal @turn.provider_profile_id, events.first["provider_profile_id"]
      assert_equal 0, events.last["data"]["tool_call_count"]
      assert_equal "sess_9", @turn.conversation.reload.claude_session_id
    end
  end

  test "the stored session id is sent back to the service for resume" do
    with_env("ASSISTANT_CLAUDE_URL" => "http://assistant-claude:8083") do
      @turn.conversation.update!(claude_session_id: "sess_prev")
      seen = nil
      poster = ->(body) { seen = body; { "session_id" => "sess_prev", "reply" => "ok" } }
      Assistant::ClaudeCodeClient.run_turn(turn: @turn, prompt: "again", poster: poster)
      assert_equal "sess_prev", seen["session_id"]
      assert_equal "again", seen["prompt"]
    end
  end

  test "blank ASSISTANT_CLAUDE_URL yields claude_not_configured" do
    with_env("ASSISTANT_CLAUDE_URL" => "") do
      events = Assistant::ClaudeCodeClient.run_turn(turn: @turn, prompt: "hi")
      assert_equal "error", events.first["kind"]
      assert_equal "claude_not_configured", events.first["data"]["code"]
    end
  end

  test "endpoint is the configured service chat endpoint" do
    with_env("ASSISTANT_CLAUDE_URL" => "http://assistant-claude:8083") do
      assert_equal "http://assistant-claude:8083/chat", Assistant::ClaudeCodeClient.endpoint
    end
  end

  test "an error envelope from the service becomes an error event" do
    with_env("ASSISTANT_CLAUDE_URL" => "http://assistant-claude:8083") do
      poster = ->(_body) { { "error" => { "code" => "claude_login_required" } } }
      events = Assistant::ClaudeCodeClient.run_turn(turn: @turn, prompt: "hi", poster: poster)
      assert_equal "claude_login_required", events.first["data"]["code"]
    end
  end

  test "an unknown service error collapses without leaking service output" do
    sensitive = "provider failed: prompt=secret session=sess_secret tool_args=private"

    with_env("ASSISTANT_CLAUDE_URL" => "http://assistant-claude:8083") do
      poster = ->(_body) { { "error" => { "code" => sensitive } } }
      events = Assistant::ClaudeCodeClient.run_turn(
        turn: @turn, prompt: "secret prompt", poster: poster
      )

      assert_equal "claude_error", events.first["data"]["code"]
      refute_includes events.to_json, sensitive
      refute_includes events.to_json, "secret prompt"
      refute_includes events.to_json, "sess_secret"
      refute_includes events.to_json, "tool_args"
    end
  end

  test "a malformed response (no session/reply) yields claude_malformed_response" do
    with_env("ASSISTANT_CLAUDE_URL" => "http://assistant-claude:8083") do
      poster = ->(_body) { { "reply" => "hi but no session" } }
      events = Assistant::ClaudeCodeClient.run_turn(turn: @turn, prompt: "hi", poster: poster)
      assert_equal "claude_malformed_response", events.first["data"]["code"]
    end
  end

  test "a whitespace-only session id is rejected before continuity changes" do
    with_env("ASSISTANT_CLAUDE_URL" => "http://assistant-claude:8083") do
      events = Assistant::ClaudeCodeClient.run_turn(
        turn: @turn,
        prompt: "hello",
        poster: ->(_request) { { "session_id" => " \t", "reply" => "Hi" } }
      )

      assert_equal "claude_malformed_response", events.first.dig("data", "code")
      assert_nil @turn.conversation.reload.claude_session_id
    end
  end

  test "a whitespace-only reply is rejected before continuity changes" do
    with_env("ASSISTANT_CLAUDE_URL" => "http://assistant-claude:8083") do
      events = Assistant::ClaudeCodeClient.run_turn(
        turn: @turn,
        prompt: "hello",
        poster: ->(_request) { { "session_id" => "sess_9", "reply" => " \n" } }
      )

      assert_equal "claude_malformed_response", events.first.dig("data", "code")
      assert_nil @turn.conversation.reload.claude_session_id
    end
  end

  test "wrong-type and oversized success fields are rejected before continuity changes" do
    malformed_bodies = [
      { "session_id" => 123, "reply" => "Hi" },
      { "session_id" => "sess_9", "reply" => [ "Hi" ] },
      { "session_id" => "s" * 256, "reply" => "Hi" },
      { "session_id" => "sess_9", "reply" => "x" * 65_537 }
    ]

    malformed_bodies.each do |body|
      @turn.conversation.update!(claude_session_id: nil)
      with_env("ASSISTANT_CLAUDE_URL" => "http://assistant-claude:8083") do
        events = Assistant::ClaudeCodeClient.run_turn(
          turn: @turn, prompt: "hello", poster: ->(_request) { body }
        )

        assert_equal "claude_malformed_response", events.first.dig("data", "code")
        assert_nil @turn.conversation.reload.claude_session_id
      end
    end
  end

  test "an oversized HTTP response is rejected while streaming without buffering body" do
    payload = JSON.generate(
      "session_id" => "sess_9",
      "reply" => "Hi",
      "padding" => "x" * (Assistant::GatewayClient::MAX_RESPONSE_BYTES + 1)
    )
    response, body_called = streaming_response(payload)

    with_env(
      "ASSISTANT_CLAUDE_URL" => "http://assistant-claude:8083",
      "ASSISTANT_CLAUDE_INGRESS_TOKEN" => "ingress-token"
    ) do
      with_http_response(response) do
        events = Assistant::ClaudeCodeClient.run_turn(turn: @turn, prompt: "hello")

        assert_equal "claude_malformed_response", events.first.dig("data", "code")
        refute body_called.call, "the untrusted response was buffered through response.body"
        assert_nil @turn.conversation.reload.claude_session_id
      end
    end
  end

  test "turn_grant is included in the request body when present" do
    with_env("ASSISTANT_CLAUDE_URL" => "http://assistant-claude:8083") do
      seen = nil
      poster = ->(body) { seen = body; { "session_id" => "sess_9", "reply" => "Hi!" } }
      Assistant::ClaudeCodeClient.run_turn(
        turn: @turn, prompt: "hello", turn_grant: "raw-grant-token", poster: poster
      )
      assert_equal "raw-grant-token", seen["turn_grant"]
    end
  end

  test "turn_grant is omitted from the request body when absent" do
    with_env("ASSISTANT_CLAUDE_URL" => "http://assistant-claude:8083") do
      seen = nil
      poster = ->(body) { seen = body; { "session_id" => "sess_9", "reply" => "Hi!" } }
      Assistant::ClaudeCodeClient.run_turn(turn: @turn, prompt: "hello", poster: poster)
      refute seen.key?("turn_grant")
    end
  end

  private

  def streaming_response(body)
    body_called = false
    response = Object.new
    response.define_singleton_method(:body) do
      body_called = true
      body
    end
    response.define_singleton_method(:read_body) do |&block|
      offset = 0
      while offset < body.bytesize
        block.call(body.byteslice(offset, 16_384))
        offset += 16_384
      end
    end
    [ response, -> { body_called } ]
  end

  def with_http_response(response)
    http = Object.new
    http.define_singleton_method(:request) do |_request, &block|
      block ? block.call(response) : response
    end
    stub_methods(Net::HTTP,
      start: ->(*, **, &block) { block.call(http) }) { yield }
  end
end
