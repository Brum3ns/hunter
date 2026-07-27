require "test_helper"

class Api::V1::Assistant::TurnsTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:one)
    @conversation = assistant_conversations(:one)
    @original_admin_username = ENV["ADMIN_USERNAME"]
    ENV["ADMIN_USERNAME"] = @admin.username
    sign_in_as(@admin)
    Assistant::Setting.instance.enable!
  end

  teardown do
    ENV["ADMIN_USERNAME"] = @original_admin_username
  end

  test "turn creation resolves disclosure before issuing a grant and never returns the raw grant" do
    target = Target.new("id" => "target-1", "target" => { "host" => "example.test" })
    delivery = nil

    with_enabled_assistant do
      stub_methods(Assistant::Context::Resolver, find: target) do
        stub_methods(Assistant::Broker, publish: ->(**attributes) { delivery = attributes.deep_dup }) do
          post "/api/v1/assistant/conversations/#{@conversation.id}/turns", params: {
            message: "Draft a safe probe",
            contexts: [ { type: "target", id: "target-1" } ]
          }, as: :json
        end
      end
    end

    assert_response :accepted
    turn = Assistant::Turn.find(response.parsed_body.fetch("id"))
    assert_equal "queued", turn.status
    assert_equal [ { "type" => "target", "id" => "target-1" } ], turn.turn_grant.resources
    assert_equal({
      "type" => "target", "id" => "target-1", "label" => "example.test",
      "serializer_version" => "v1"
    }, response.parsed_body.fetch("context_references").sole)
    raw_grant = delivery.dig(:body, "turn_grant")
    assert raw_grant.present?
    refute_includes response.body, raw_grant
    refute_includes response.body, turn.turn_grant.token_digest
    refute_includes response.body, "turn_grant"

    get "/api/v1/assistant/conversations/#{@conversation.id}"
    assert_response :success
    summary = response.parsed_body.fetch("turns").find { |item| item.fetch("id") == turn.id }
    assert_equal "queued", summary.fetch("status")
    refute_includes response.body, raw_grant
  end

  test "turn creation rejects missing context without persisting or dispatching" do
    dispatched = false

    assert_no_difference -> { Assistant::Turn.count } do
      with_enabled_assistant do
        stub_methods(Assistant::Context::Resolver, find: nil) do
          stub_methods(Assistant::Broker, publish: ->(**) { dispatched = true }) do
            post "/api/v1/assistant/conversations/#{@conversation.id}/turns", params: {
              message: "Draft a probe", contexts: [ { type: "target", id: "missing" } ]
            }, as: :json
          end
        end
      end
    end

    assert_response :unprocessable_entity
    assert_equal "context_invalid", response.parsed_body.fetch("error")
    assert_equal({ "index" => 0, "code" => "not_found" }, response.parsed_body.fetch("errors").sole)
    refute dispatched
  end

  test "turn polling and cancellation are owner scoped and cancellation revokes authority" do
    turn = assistant_turns(:created)
    turn.conversation.messages.create!(
      turn: turn, role: "user", body: "poll me", sequence: 1
    )
    Assistant::Grants::Issuer.call(
      turn: turn, resources: [], tools: [ "get_authoring_policy" ]
    )

    get "/api/v1/assistant/turns/#{turn.id}"
    assert_response :success
    assert_equal "created", response.parsed_body.fetch("status")
    assert_equal "poll me", response.parsed_body.dig("messages", 0, "body")
    refute_includes response.body, "token_digest"
    refute_includes response.body, "turn_grant"

    post "/api/v1/assistant/turns/#{turn.id}/cancel", as: :json
    assert_response :success
    assert_equal "canceled", response.parsed_body.fetch("status")
    assert_equal "canceled", turn.reload.status
    assert_not_nil turn.turn_grant.reload.revoked_at

    get "/api/v1/assistant/turns/#{assistant_turns(:other_user).id}"
    assert_response :not_found
    post "/api/v1/assistant/turns/#{assistant_turns(:other_user).id}/cancel", as: :json
    assert_response :not_found
  end

  test "a late event cannot reopen a canceled turn" do
    turn = assistant_turns(:created)
    post "/api/v1/assistant/turns/#{turn.id}/cancel", as: :json
    assert_response :success

    payload = {
      "schema_version" => 1,
      "event_id" => SecureRandom.uuid,
      "correlation_id" => turn.correlation_id,
      "turn_id" => turn.id,
      "provider_profile_id" => turn.provider_profile_id,
      "kind" => "assistant_message",
      "data" => { "body" => "too late" }
    }
    error = assert_raises(Assistant::EventIngestor::InvalidEvent) do
      Assistant::EventIngestor.call(payload)
    end
    assert_equal "terminal_replay", error.code
    assert_equal "canceled", turn.reload.status
  end

  test "polling reconciles a nonterminal turn whose undispatched grant expired" do
    turn = assistant_turns(:created)
    Assistant::Grants::Issuer.call(
      turn: turn, resources: [], tools: [ "get_authoring_policy" ]
    )
    turn.turn_grant.update_column(:expires_at, 1.minute.ago)

    get "/api/v1/assistant/turns/#{turn.id}"

    assert_response :success
    assert_equal "interrupted", response.parsed_body.fetch("status")
    assert_equal "assistant_turn_expired", response.parsed_body.fetch("error_code")
    assert_not_nil turn.turn_grant.reload.revoked_at
    assert Assistant::AuditEvent.exists?(event: "turn.expired", turn_id: turn.id)
  end

  test "draft disclosure is owner scoped and derives save eligibility from current server validation" do
    valid = Assistant::Draft.create!(
      conversation: @conversation,
      turn: assistant_turns(:created),
      artifact_type: "whiterabbit_template",
      name: "<img src=x onerror=alert(1)>",
      content: "<script>alert(1)</script>\e[31m",
      validation_details: {
        "codes" => [], "messages" => [ "<b>valid</b>\u0000" ]
      },
      validation_status: "valid",
      validation_version: Assistant::DraftValidation::Whiterabbit::VALIDATION_VERSION
    )

    get "/api/v1/assistant/drafts/#{valid.id}"
    assert_response :success
    assert_equal true, response.parsed_body.fetch("can_save")
    assert_equal "<script>alert(1)</script>\e[31m", response.parsed_body.fetch("content")
    assert_equal [ "<b>valid</b>\u0000" ], response.parsed_body.dig("validation", "messages")

    stale = Assistant::Draft.create!(
      conversation: @conversation,
      turn: assistant_turns(:created),
      artifact_type: "whiterabbit_template",
      name: "Stale",
      content: "commands: []",
      validation_details: {},
      validation_status: "valid",
      validation_version: "old-version"
    )
    get "/api/v1/assistant/drafts/#{stale.id}"
    assert_response :success
    assert_equal false, response.parsed_body.fetch("can_save")

    foreign = Assistant::Draft.create!(
      conversation: assistant_conversations(:other_user),
      turn: assistant_turns(:other_user),
      artifact_type: "ansible_playbook",
      name: "Foreign",
      content: "---\n- hosts: all\n",
      validation_details: {},
      validation_status: "pending",
      validation_version: Assistant::ValidationDispatcher::VALIDATION_VERSION
    )
    get "/api/v1/assistant/drafts/#{foreign.id}"
    assert_response :not_found
  end

  test "dispatch failure returns a stable retryable interruption without leaking authority" do
    with_enabled_assistant do
      stub_methods(Assistant::Broker, publish: ->(**) { raise "broker down with internal detail" }) do
        post "/api/v1/assistant/conversations/#{@conversation.id}/turns", params: {
          message: "Draft without context", contexts: []
        }, as: :json
      end
    end

    assert_response :service_unavailable
    assert_equal "assistant_dispatch_unavailable", response.parsed_body.fetch("error")
    turn = Assistant::Turn.find(response.parsed_body.fetch("id"))
    assert_equal "interrupted", turn.status
    refute_includes response.body, "broker down"
    refute_includes response.body, "turn_grant"
  end

  test "turn-start rate limits return a stable retryable response" do
    error = Assistant::RateLimiter::LimitExceeded.new(
      "turn_rate_minute_exceeded", retry_after_seconds: 17
    )

    stub_methods(Assistant::RateLimiter, consume!: ->(**) { raise error }) do
      with_enabled_assistant do
        post "/api/v1/assistant/conversations/#{@conversation.id}/turns", params: {
          message: "Too fast", contexts: []
        }, as: :json
      end
    end

    assert_response :too_many_requests
    assert_equal "turn_rate_minute_exceeded", response.parsed_body.fetch("error")
    assert_equal "17", response.headers.fetch("Retry-After")
  end

  private

  def with_enabled_assistant(&block)
    stub_methods(Assistant::Config, { enabled?: true, max_records: 10 }, &block)
  end
end
