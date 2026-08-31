require "test_helper"

class Assistant::CodexClientTest < ActiveSupport::TestCase
  SERVICE_URL = "http://assistant-codex:8084"

  setup do
    @conversation = assistant_conversations(:codex)
    @conversation.update!(codex_thread_id: nil)
    @turn = Assistant::Turn.create!(
      conversation: @conversation,
      user: @conversation.user,
      provider_profile: @conversation.provider_profile
    )
  end

  test "success stores the thread id and returns the shared event contract" do
    with_codex_env do
      poster = ->(_body) { { "thread_id" => "thr_9", "reply" => "Hi" } }

      events = Assistant::CodexClient.run_turn(
        turn: @turn, prompt: "hello", poster: poster
      )

      assert_equal %w[assistant_message completed], events.map { |event| event["kind"] }
      assert_equal "Hi", events.first.dig("data", "body")
      assert_equal @turn.correlation_id, events.first["correlation_id"]
      assert_equal @turn.id, events.first["turn_id"]
      assert_equal @turn.provider_profile_id, events.first["provider_profile_id"]
      assert_equal 1, events.first["schema_version"]
      assert_equal(
        { "input_tokens" => 0, "output_tokens" => 0, "tool_call_count" => 0 },
        events.last["data"]
      )
      assert_equal "thr_9", @turn.conversation.reload.codex_thread_id
    end
  end

  test "request body contains only prompt and persisted resume state" do
    with_codex_env do
      @turn.conversation.update!(codex_thread_id: "thr_old")
      seen = nil

      Assistant::CodexClient.run_turn(
        turn: @turn,
        prompt: "again",
        poster: lambda { |body|
          seen = body
          { "thread_id" => "thr_old", "reply" => "ok" }
        }
      )

      assert_equal(
        { "prompt" => "again", "thread_id" => "thr_old" },
        seen
      )
    end
  end

  test "new turns send the exact grantless request body" do
    with_codex_env do
      seen = nil

      Assistant::CodexClient.run_turn(
        turn: @turn,
        prompt: "hello",
        poster: lambda { |body|
          seen = body
          { "thread_id" => "thr_new", "reply" => "ok" }
        }
      )

      assert_equal({ "prompt" => "hello", "thread_id" => nil }, seen)
    end
  end

  test "endpoint is the configured service chat endpoint" do
    with_codex_env do
      assert_equal "#{SERVICE_URL}/chat", Assistant::CodexClient.endpoint
    end
  end

  test "blank service URL yields codex_not_configured without posting" do
    with_codex_env(url: "") do
      events = Assistant::CodexClient.run_turn(
        turn: @turn,
        prompt: "secret prompt",
        poster: ->(_body) { flunk "an unconfigured client must not post" }
      )

      assert_error_code "codex_not_configured", events
    end
  end

  test "missing ingress token yields codex_not_configured" do
    with_codex_env(token: nil) do
      events = Assistant::CodexClient.run_turn(turn: @turn, prompt: "secret prompt")

      assert_error_code "codex_not_configured", events
    end
  end

  test "known service errors retain only their stable codes" do
    %w[codex_login_required codex_usage_limit codex_error].each do |code|
      with_codex_env do
        events = Assistant::CodexClient.run_turn(
          turn: @turn,
          prompt: "secret prompt",
          poster: ->(_body) { { "error" => { "code" => code } } }
        )

        assert_error_code code, events
      end
    end
  end

  test "unknown service errors collapse without leaking service output" do
    sensitive = "provider failed: prompt=secret session=thr_secret tool_args=private"

    with_codex_env do
      events = Assistant::CodexClient.run_turn(
        turn: @turn,
        prompt: "secret prompt",
        poster: ->(_body) { { "error" => { "code" => sensitive } } }
      )

      assert_error_code "codex_error", events
      refute_includes events.to_json, sensitive
      refute_includes events.to_json, "secret prompt"
      refute_includes events.to_json, "thr_secret"
      refute_includes events.to_json, "tool_args"
    end
  end

  test "malformed success payloads yield codex_malformed_response" do
    [ nil, {}, { "thread_id" => "thr_9" }, { "reply" => "Hi" } ].each do |body|
      with_codex_env do
        events = Assistant::CodexClient.run_turn(
          turn: @turn, prompt: "hello", poster: ->(_request) { body }
        )

        assert_error_code "codex_malformed_response", events
      end
    end
  end

  test "a whitespace-only thread id is rejected before continuity changes" do
    with_codex_env do
      events = Assistant::CodexClient.run_turn(
        turn: @turn,
        prompt: "hello",
        poster: ->(_request) { { "thread_id" => " \t", "reply" => "Hi" } }
      )

      assert_error_code "codex_malformed_response", events
      assert_nil @turn.conversation.reload.codex_thread_id
    end
  end

  test "a whitespace-only reply is rejected before continuity changes" do
    with_codex_env do
      events = Assistant::CodexClient.run_turn(
        turn: @turn,
        prompt: "hello",
        poster: ->(_request) { { "thread_id" => "thr_9", "reply" => " \n" } }
      )

      assert_error_code "codex_malformed_response", events
      assert_nil @turn.conversation.reload.codex_thread_id
    end
  end

  test "wrong-type and oversized success fields are rejected before continuity changes" do
    malformed_bodies = [
      { "thread_id" => 123, "reply" => "Hi" },
      { "thread_id" => "thr_9", "reply" => [ "Hi" ] },
      { "thread_id" => "t" * 256, "reply" => "Hi" },
      { "thread_id" => "thr_9", "reply" => "x" * 65_537 }
    ]

    malformed_bodies.each do |body|
      @turn.conversation.update!(codex_thread_id: nil)
      with_codex_env do
        events = Assistant::CodexClient.run_turn(
          turn: @turn, prompt: "hello", poster: ->(_request) { body }
        )

        assert_error_code "codex_malformed_response", events
        assert_nil @turn.conversation.reload.codex_thread_id
      end
    end
  end

  test "an oversized HTTP response is rejected while streaming without buffering body" do
    payload = JSON.generate(
      "thread_id" => "thr_9",
      "reply" => "Hi",
      "padding" => "x" * (Assistant::GatewayClient::MAX_RESPONSE_BYTES + 1)
    )
    response, body_called = streaming_response(payload)

    with_codex_env do
      with_http_response(response) do
        events = Assistant::CodexClient.run_turn(turn: @turn, prompt: "hello")

        assert_error_code "codex_malformed_response", events
        refute body_called.call, "the untrusted response was buffered through response.body"
        assert_nil @turn.conversation.reload.codex_thread_id
      end
    end
  end

  test "invalid JSON yields codex_malformed_response" do
    response, = streaming_response("not-json")

    with_codex_env do
      with_http_response(response) do
        events = Assistant::CodexClient.run_turn(turn: @turn, prompt: "hello")

        assert_error_code "codex_malformed_response", events
      end
    end
  end

  test "all bounded timeout faults yield codex_timeout" do
    [ Net::OpenTimeout.new("secret"), Net::ReadTimeout.new("secret"),
      Timeout::Error.new("secret") ].each do |error|
      assert_transport_error error, "codex_timeout"
    end
  end

  test "DNS faults yield codex_dns_failure" do
    assert_transport_error SocketError.new("secret host"), "codex_dns_failure"
  end

  test "refused connections yield codex_connection_refused" do
    assert_transport_error Errno::ECONNREFUSED.new("secret endpoint"),
      "codex_connection_refused"
  end

  test "other connection faults yield codex_unreachable" do
    [ IOError.new("secret response"), OpenSSL::SSL::SSLError.new("secret TLS") ].each do |error|
      assert_transport_error error, "codex_unreachable"
    end
  end

  private

  def with_codex_env(url: SERVICE_URL, token: "ingress-token", &block)
    with_env(
      "ASSISTANT_CODEX_URL" => url,
      "ASSISTANT_CODEX_INGRESS_TOKEN" => token,
      &block
    )
  end

  def with_env(values)
    originals = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    originals.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def assert_transport_error(error, expected_code)
    with_codex_env do
      stub_methods(Net::HTTP, start: ->(*) { raise error }) do
        events = Assistant::CodexClient.run_turn(turn: @turn, prompt: "secret prompt")

        assert_error_code expected_code, events
        refute_includes events.to_json, error.message
        refute_includes events.to_json, "secret prompt"
      end
    end
  end

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

  def assert_error_code(expected, events)
    assert_equal 1, events.length
    assert_equal "error", events.first["kind"]
    assert_equal expected, events.first.dig("data", "code")
  end
end
