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
