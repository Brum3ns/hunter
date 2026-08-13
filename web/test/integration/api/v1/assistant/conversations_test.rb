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

  # Every input Assistant::Activation.state consults is pinned here, in the order it
  # consults them: the kill override, then the required settings, then the retention
  # window, then the provider credential variables. Two of these must be pinned rather
  # than inherited or the assertion below is decided by a path this test does not
  # control: docker-compose defaults ASSISTANT_ENABLED to "false" (short-circuiting to
  # disabled_by_environment inside the operator's own container), and an out-of-range
  # ASSISTANT_TRANSCRIPT_DAYS or ASSISTANT_AUDIT_DAYS makes
  # Assistant::Config.configuration_reasons return invalid_retention_window, which
  # Activation.state reports before it ever consults credentials.
  test "the bootstrap payload discloses the disabled reason without leaking secrets" do
    original_enabled = ENV["ASSISTANT_ENABLED"]
    original_command_allowlist = ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"]
    original_ansible_allowlist = ENV["ASSISTANT_ANSIBLE_MODULE_ALLOWLIST"]
    original_transcript_days = ENV["ASSISTANT_TRANSCRIPT_DAYS"]
    original_audit_days = ENV["ASSISTANT_AUDIT_DAYS"]
    original_anthropic_key = ENV["ASSISTANT_ANTHROPIC_API_KEY"]
    original_openai_key = ENV["ASSISTANT_OPENAI_API_KEY"]
    ENV["ASSISTANT_ENABLED"] = nil
    ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"] = "httpx"
    ENV["ASSISTANT_ANSIBLE_MODULE_ALLOWLIST"] = "ansible.builtin.debug"
    ENV["ASSISTANT_TRANSCRIPT_DAYS"] = "7"
    ENV["ASSISTANT_AUDIT_DAYS"] = "90"
    ENV.delete("ASSISTANT_ANTHROPIC_API_KEY")
    ENV.delete("ASSISTANT_OPENAI_API_KEY")

    begin
      get "/api/v1/assistant/bootstrap", headers: { "Accept" => "application/json" }
    ensure
      ENV["ASSISTANT_ENABLED"] = original_enabled
      ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"] = original_command_allowlist
      ENV["ASSISTANT_ANSIBLE_MODULE_ALLOWLIST"] = original_ansible_allowlist
      ENV["ASSISTANT_TRANSCRIPT_DAYS"] = original_transcript_days
      ENV["ASSISTANT_AUDIT_DAYS"] = original_audit_days
      ENV["ASSISTANT_ANTHROPIC_API_KEY"] = original_anthropic_key
      ENV["ASSISTANT_OPENAI_API_KEY"] = original_openai_key
    end

    assert_response :success
    payload = response.parsed_body.fetch("settings")
    assert_equal "no_provider_credentials", payload.fetch("disabled_reason")
    assert_equal %w[anthropic_primary openai_primary], payload.fetch("providers").map { |p| p["slug"] }.sort
    refute_match(%r{/run/secrets}, response.body, "a secret path leaked to the browser")
  end

  test "conversation pins an enabled profile owned by the admin session" do
    Assistant::Setting.instance.enable!

    stub_methods(Assistant::Config, enabled?: true) do
      post "/api/v1/assistant/conversations",
        params: { provider_profile_id: assistant_provider_profiles(:openai).id }, as: :json
    end

    assert_response :created
    body = response.parsed_body
    assert_equal assistant_provider_profiles(:openai).id, body.dig("provider_profile", "id")
    assert_equal @admin.id, Assistant::Conversation.find(body.fetch("id")).user_id
  end

  test "conversation creation fails closed when either kill switch is off" do
    Assistant::Setting.instance.enable!

    stub_methods(Assistant::Config, enabled?: false) do
      post "/api/v1/assistant/conversations",
        params: { provider_profile_id: assistant_provider_profiles(:openai).id }, as: :json
    end
    assert_response :service_unavailable
    assert_equal "assistant_disabled", response.parsed_body["error"]

    Assistant::Setting.instance.disable!(user: @admin)
    stub_methods(Assistant::Config, enabled?: true) do
      post "/api/v1/assistant/conversations",
        params: { provider_profile_id: assistant_provider_profiles(:openai).id }, as: :json
    end
    assert_response :service_unavailable
  end

  test "conversation creation rejects a disabled profile" do
    Assistant::Setting.instance.enable!

    stub_methods(Assistant::Config, enabled?: true) do
      post "/api/v1/assistant/conversations",
        params: { provider_profile_id: assistant_provider_profiles(:anthropic).id }, as: :json
    end

    assert_response :unprocessable_entity
    assert_includes response.parsed_body.fetch("errors").fetch("provider_profile"), "must be enabled"
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
    refute_includes response.body, "secret_ref"

    get "/api/v1/assistant/conversations"
    assert_response :success
    assert_equal [ assistant_conversations(:one).id ],
      response.parsed_body.fetch("conversations").map { |item| item.fetch("id") }
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
