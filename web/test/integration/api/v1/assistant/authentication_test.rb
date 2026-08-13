require "test_helper"

class Api::V1::Assistant::AuthenticationTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:one)
    @original_admin_username = ENV["ADMIN_USERNAME"]
    ENV["ADMIN_USERNAME"] = @admin.username
  end

  teardown do
    ENV["ADMIN_USERNAME"] = @original_admin_username
  end

  test "anonymous requests require a browser session" do
    get "/api/v1/assistant/bootstrap"

    assert_response :unauthorized
    assert_equal "session_required", response.parsed_body["error"]
  end

  test "a session for a non-administrator is forbidden" do
    sign_in_as(users(:two))

    get "/api/v1/assistant/bootstrap"

    assert_response :forbidden
    assert_equal "assistant_admin_required", response.parsed_body["error"]
  end

  test "valid bearer token is rejected on the browser assistant API" do
    _record, raw = ApiToken.generate(user: @admin, name: "all", scopes: [ "*" ])

    get "/api/v1/assistant/bootstrap", headers: { "Authorization" => "Bearer #{raw}" }

    assert_response :unauthorized
    assert_equal "session_required", response.parsed_body["error"]
  end

  test "an authorization header is rejected even with an administrator session" do
    sign_in_as(@admin)

    get "/api/v1/assistant/bootstrap", headers: { "Authorization" => "Bearer ignored" }

    assert_response :unauthorized
    assert_equal "session_required", response.parsed_body["error"]
  end

  test "cookie writes preserve CSRF protection" do
    sign_in_as(@admin)
    Assistant::Setting.instance.enable!
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    stub_methods(Assistant::Config, enabled?: true) do
      post "/api/v1/assistant/conversations",
        params: { provider_profile_id: assistant_provider_profiles(:openai).id }, as: :json
    end

    assert_response :forbidden
    assert_equal "invalid_csrf_token", response.parsed_body["error"]
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end

  test "conversation organization rejects bearer and non-administrator writes" do
    conversation = assistant_conversations(:one)
    Assistant::Setting.instance.update!(
      assistant_enabled: true,
      conversation_management_enabled: true
    )
    _record, raw = ApiToken.generate(user: @admin, name: "all", scopes: [ "*" ])

    patch "/api/v1/assistant/conversations/#{conversation.id}",
      params: { title: "Bearer" }, as: :json,
      headers: { "Authorization" => "Bearer #{raw}" }
    assert_response :unauthorized
    assert_equal "session_required", response.parsed_body.fetch("error")

    sign_in_as(users(:two))
    patch "/api/v1/assistant/conversations/#{conversation.id}",
      params: { title: "Other user" }, as: :json
    assert_response :forbidden
    assert_equal "assistant_admin_required", response.parsed_body.fetch("error")
    assert_equal "First assistant conversation", conversation.reload.title
  end

  test "conversation organization preserves CSRF protection" do
    sign_in_as(@admin)
    Assistant::Setting.instance.update!(
      assistant_enabled: true,
      conversation_management_enabled: true
    )
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    stub_methods(Assistant::Config, enabled?: true) do
      patch "/api/v1/assistant/conversations/#{assistant_conversations(:one).id}",
        params: { title: "Forged" }, as: :json
    end

    assert_response :forbidden
    assert_equal "invalid_csrf_token", response.parsed_body.fetch("error")
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end
end
