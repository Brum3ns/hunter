require "test_helper"

class Api::V1::Assistant::ConversationsTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:one)
    @original_admin_username = ENV["ADMIN_USERNAME"]
    ENV["ADMIN_USERNAME"] = @admin.username
    sign_in_as(@admin)
  end

  teardown do
    ENV["ADMIN_USERNAME"] = @original_admin_username
  end

  test "the bootstrap payload exposes only reviewed direct chat backends" do
    state = Assistant::Activation::State.new(
      active: true,
      available_slugs: %w[codex claude_code],
      reason: "active"
    )

    stub_methods(Assistant::Activation, state: state) do
      get "/api/v1/assistant/bootstrap", headers: { "Accept" => "application/json" }
    end

    assert_response :success
    payload = response.parsed_body
    assert payload.key?("chat_backends"), "bootstrap omitted chat_backends"
    assert_equal %w[codex claude_code], payload.fetch("chat_backends").map { |item| item.fetch("slug") }
    assert_equal %w[openai anthropic], payload.fetch("chat_backends").map { |item| item.fetch("brand") }
    refute payload.key?("provider_profiles")
    refute payload.fetch("settings").key?("providers")
    refute_match(/secret_ref|provider key|session_id/i, response.body)
  end

  test "one backend slug creates a pinned direct conversation" do
    Assistant::Setting.instance.enable!

    stub_methods(Assistant::Config, enabled?: true) do
      post "/api/v1/assistant/conversations",
        params: { backend: "codex" }, as: :json
    end

    assert_response :created
    body = response.parsed_body
    assert_equal "codex", body.fetch("backend")
    assert_equal "openai", body.fetch("brand")
    assert_equal false, body.fetch("legacy")
    refute body.key?("provider_profile")
    conversation = Assistant::Conversation.find(body.fetch("id"))
    assert_equal @admin.id, conversation.user_id
    assert_equal assistant_provider_profiles(:codex), conversation.provider_profile
  end

  test "profile ids unknown keys non-string values and legacy slugs cannot create conversations" do
    Assistant::Setting.instance.enable!
    bodies = [
      { provider_profile_id: assistant_provider_profiles(:openai).id },
      { backend: "openai_primary" },
      { backend: "codex", model: "anything" },
      { backend: 123 }
    ]

    bodies.each do |body|
      assert_no_difference -> { Assistant::Conversation.count } do
        stub_methods(Assistant::Config, enabled?: true) do
          post "/api/v1/assistant/conversations", params: body, as: :json
        end
      end
      assert_includes [ 400, 404 ], response.status
    end
  end

  test "conversation creation fails closed when either kill switch is off" do
    Assistant::Setting.instance.enable!

    stub_methods(Assistant::Config, enabled?: false) do
      post "/api/v1/assistant/conversations",
        params: { backend: "codex" }, as: :json
    end
    assert_response :service_unavailable
    assert_equal "assistant_disabled", response.parsed_body["error"]

    Assistant::Setting.instance.disable!(user: @admin)
    stub_methods(Assistant::Config, enabled?: true) do
      post "/api/v1/assistant/conversations",
        params: { backend: "codex" }, as: :json
    end
    assert_response :service_unavailable
  end

  test "conversation creation hides an unavailable direct profile" do
    Assistant::Setting.instance.enable!
    assistant_provider_profiles(:codex).update!(enabled: false)

    stub_methods(Assistant::Config, enabled?: true) do
      post "/api/v1/assistant/conversations",
        params: { backend: "codex" }, as: :json
    end

    assert_response :not_found
  end

  test "rename accepts only an owned bounded title and audits no title content" do
    conversation = assistant_conversations(:one)

    assert_difference -> { Assistant::AuditEvent.where(event: "conversation.renamed").count }, 1 do
      with_conversation_management do
        patch "/api/v1/assistant/conversations/#{conversation.id}",
          params: { title: "  Renamed chat  " }, as: :json
      end
    end

    assert_response :success
    assert_equal "Renamed chat", response.parsed_body.fetch("title")
    assert_equal "Renamed chat", conversation.reload.title
    event = Assistant::AuditEvent.find_by!(event: "conversation.renamed")
    refute_includes event.attributes.to_json, "Renamed chat"
  end

  test "rename rejects unknown missing and non-string request shapes" do
    conversation = assistant_conversations(:one)
    invalid_bodies = [
      { title: "Allowed", status: "closed" },
      {},
      { title: [ "not", "a", "string" ] }
    ]

    invalid_bodies.each do |params|
      with_conversation_management do
        patch "/api/v1/assistant/conversations/#{conversation.id}", params: params, as: :json
      end

      assert_response :bad_request
      assert_equal "bad_request", response.parsed_body.fetch("error")
      assert_equal "First assistant conversation", conversation.reload.title
    end
    refute Assistant::AuditEvent.exists?(event: "conversation.renamed")
  end

  test "rename is not exposed through a PUT alias" do
    conversation = assistant_conversations(:one)

    with_conversation_management do
      put "/api/v1/assistant/conversations/#{conversation.id}",
        params: { title: "Wrong verb" }, as: :json
    end

    assert_response :not_found
    assert_equal "First assistant conversation", conversation.reload.title
    refute Assistant::AuditEvent.exists?(event: "conversation.renamed")
  end

  test "rename returns validation errors for blank and oversized titles" do
    conversation = assistant_conversations(:one)

    [ "   ", "x" * 201 ].each do |title|
      with_conversation_management do
        patch "/api/v1/assistant/conversations/#{conversation.id}",
          params: { title: title }, as: :json
      end

      assert_response :unprocessable_entity
      assert_equal "validation_failed", response.parsed_body.fetch("error")
      assert response.parsed_body.dig("errors", "title").present?
    end
    assert_equal "First assistant conversation", conversation.reload.title
  end

  test "rename does not disclose or mutate a foreign conversation" do
    foreign = assistant_conversations(:other_user)

    with_conversation_management do
      patch "/api/v1/assistant/conversations/#{foreign.id}",
        params: { title: "Stolen" }, as: :json
    end

    assert_response :not_found
    assert_equal "Other user's conversation", foreign.reload.title
    refute Assistant::AuditEvent.exists?(event: "conversation.renamed")
  end

  test "reorder persists and returns the authoritative complete owned order" do
    first = assistant_conversations(:one)
    second = Assistant::Conversation.start!(
      user: @admin, provider_profile: assistant_provider_profiles(:openai)
    )

    with_conversation_management do
      patch "/api/v1/assistant/conversations/order",
        params: { conversation_ids: [ first.id, second.id ] }, as: :json
    end

    assert_response :success
    assert_equal [ first.id, second.id ],
      response.parsed_body.fetch("conversations").map { |item| item.fetch("id") }
    assert_equal [ first.id, second.id ],
      @admin.assistant_conversations.history_ordered.pluck(:id)
  end

  test "reorder separates malformed and stale orders without partial writes" do
    first = assistant_conversations(:one)
    second = Assistant::Conversation.start!(
      user: @admin, provider_profile: assistant_provider_profiles(:openai)
    )
    before = @admin.assistant_conversations.order(:id).pluck(:id, :history_position)

    [
      { conversation_ids: [ first.id, first.id ] },
      { conversation_ids: [ first.id.to_s, second.id ] },
      { conversation_ids: [ first.id, second.id ], extra: true }
    ].each do |params|
      with_conversation_management do
        patch "/api/v1/assistant/conversations/order", params: params, as: :json
      end

      expected_status = params.key?(:extra) ? :bad_request : :unprocessable_entity
      assert_response expected_status
      expected_code = params.key?(:extra) ? "bad_request" : "invalid_order"
      assert_equal expected_code, response.parsed_body.fetch("error")
      assert_equal before, @admin.assistant_conversations.order(:id).pluck(:id, :history_position)
    end

    with_conversation_management do
      patch "/api/v1/assistant/conversations/order",
        params: { conversation_ids: [ first.id ] }, as: :json
    end
    assert_response :conflict
    assert_equal "conversation_order_stale", response.parsed_body.fetch("error")
    assert_equal before, @admin.assistant_conversations.order(:id).pluck(:id, :history_position)
    refute Assistant::AuditEvent.exists?(event: "conversation.reordered")
  end

  test "organization writes fail closed when either activation or their toggle is off" do
    conversation = assistant_conversations(:one)
    setting = Assistant::Setting.instance
    setting.update!(assistant_enabled: true, conversation_management_enabled: true)

    stub_methods(Assistant::Config, enabled?: false) do
      patch "/api/v1/assistant/conversations/#{conversation.id}",
        params: { title: "No" }, as: :json
    end
    assert_response :service_unavailable
    assert_equal "assistant_disabled", response.parsed_body.fetch("error")

    setting.update!(conversation_management_enabled: false)
    stub_methods(Assistant::Config, enabled?: true) do
      patch "/api/v1/assistant/conversations/#{conversation.id}",
        params: { title: "Still no" }, as: :json
    end
    assert_response :service_unavailable
    assert_equal "conversation_management_disabled", response.parsed_body.fetch("error")
    assert_equal "First assistant conversation", conversation.reload.title
  end

  test "show and destroy are scoped to the session owner" do
    get "/api/v1/assistant/conversations/#{assistant_conversations(:other_user).id}"
    assert_response :not_found

    assert_no_difference -> { Assistant::Conversation.count } do
      delete "/api/v1/assistant/conversations/#{assistant_conversations(:other_user).id}"
    end
    assert_response :not_found

    assert_difference -> { Assistant::Conversation.count }, -1 do
      assert_difference -> { Assistant::AuditEvent.where(event: "conversation.deleted").count }, 1 do
      delete "/api/v1/assistant/conversations/#{assistant_conversations(:one).id}"
      end
    end
    assert_response :no_content
    event = Assistant::AuditEvent.find_by!(event: "conversation.deleted")
    assert_equal @admin.id, event.user_id
    assert_equal "assistant_conversation", event.target_type
    refute_includes event.attributes.to_json, "First assistant conversation"
  end

  test "bootstrap and index expose only safe administrator-owned records" do
    get "/api/v1/assistant/bootstrap"
    assert_response :success
    assert_equal [ assistant_conversations(:one).id ],
      response.parsed_body.fetch("conversations").map { |item| item.fetch("id") }
    legacy = response.parsed_body.fetch("conversations").sole
    assert legacy.key?("backend"), "conversation omitted backend"
    assert_nil legacy.fetch("backend")
    assert_nil legacy.fetch("brand")
    assert_equal true, legacy.fetch("legacy")
    refute legacy.key?("provider_profile")
    refute_match(/secret_ref|session_id/i, response.body)

    get "/api/v1/assistant/conversations"
    assert_response :success
    assert_equal [ assistant_conversations(:one).id ],
      response.parsed_body.fetch("conversations").map { |item| item.fetch("id") }
    assert_equal true, response.parsed_body.fetch("conversations").sole.fetch("legacy")
  end

  private

  def with_conversation_management
    Assistant::Setting.instance.update!(
      assistant_enabled: true,
      conversation_management_enabled: true
    )
    stub_methods(Assistant::Config, enabled?: true) { yield }
  end
end
