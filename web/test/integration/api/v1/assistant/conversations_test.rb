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
  # window, then the credential directory. Two of these must be pinned rather than
  # inherited or the assertion below is decided by a path this test does not control:
  # docker-compose defaults ASSISTANT_ENABLED to "false" (short-circuiting to
  # disabled_by_environment inside the operator's own container), and an out-of-range
  # ASSISTANT_TRANSCRIPT_DAYS or ASSISTANT_AUDIT_DAYS makes
  # Assistant::Config.configuration_reasons return invalid_retention_window, which
  # Activation.state reports before it ever consults credentials.
  test "the bootstrap payload discloses the disabled reason without leaking paths" do
    original_enabled = ENV["ASSISTANT_ENABLED"]
    original_command_allowlist = ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"]
    original_ansible_allowlist = ENV["ASSISTANT_ANSIBLE_MODULE_ALLOWLIST"]
    original_transcript_days = ENV["ASSISTANT_TRANSCRIPT_DAYS"]
    original_audit_days = ENV["ASSISTANT_AUDIT_DAYS"]
    ENV["ASSISTANT_ENABLED"] = nil
    ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"] = "httpx"
    ENV["ASSISTANT_ANSIBLE_MODULE_ALLOWLIST"] = "ansible.builtin.debug"
    ENV["ASSISTANT_TRANSCRIPT_DAYS"] = "7"
    ENV["ASSISTANT_AUDIT_DAYS"] = "90"

    empty_directory = nil
    begin
      Dir.mktmpdir do |dir|
        empty_directory = dir
        stub_const(Assistant::ProviderCredentials, :DEFAULT_DIRECTORY, dir) do
          get "/api/v1/assistant/bootstrap", headers: { "Accept" => "application/json" }
        end
      end
    ensure
      ENV["ASSISTANT_ENABLED"] = original_enabled
      ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"] = original_command_allowlist
      ENV["ASSISTANT_ANSIBLE_MODULE_ALLOWLIST"] = original_ansible_allowlist
      ENV["ASSISTANT_TRANSCRIPT_DAYS"] = original_transcript_days
      ENV["ASSISTANT_AUDIT_DAYS"] = original_audit_days
    end

    assert_response :success
    payload = response.parsed_body.fetch("settings")
    assert_equal "no_provider_credentials", payload.fetch("disabled_reason")
    assert_equal %w[anthropic_primary openai_primary], payload.fetch("providers").map { |p| p["slug"] }.sort
    refute_match(%r{/run/secrets}, response.body, "a secret path leaked to the browser")
    refute_includes response.body, empty_directory, "a temp directory path leaked to the browser"
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

  test "show and destroy are scoped to the session owner" do
    get "/api/v1/assistant/conversations/#{assistant_conversations(:other_user).id}"
    assert_response :not_found

    assert_no_difference -> { Assistant::Conversation.count } do
      delete "/api/v1/assistant/conversations/#{assistant_conversations(:other_user).id}"
    end
    assert_response :not_found

    assert_difference -> { Assistant::Conversation.count }, -1 do
      delete "/api/v1/assistant/conversations/#{assistant_conversations(:one).id}"
    end
    assert_response :no_content
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
end
