require "test_helper"

class Api::V1::Assistant::ContextTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:one)
    @original_admin_username = ENV["ADMIN_USERNAME"]
    ENV["ADMIN_USERNAME"] = @admin.username
    sign_in_as(@admin)
    Assistant::Setting.instance.enable!
  end

  teardown do
    ENV["ADMIN_USERNAME"] = @original_admin_username
  end

  test "options are bounded and expose only type id and label" do
    rows = 25.times.map { |index| { type: "target", id: index.to_s, label: "Target #{index}", raw: "no" } }

    stub_methods(Assistant::Config, enabled?: true) do
      stub_methods(Assistant::Context::Resolver, options: rows) do
        get "/api/v1/assistant/context_options", params: { type: "target", q: "example" }
      end
    end

    assert_response :success
    options = response.parsed_body.fetch("options")
    assert_equal 20, options.length
    assert_equal %w[id label type], options.first.keys.sort
    refute_includes response.body, "raw"
  end

  test "preview resolves exact references and returns sanitized envelopes" do
    target = Target.new("id" => "a", "target" => { "host" => "example.test" })

    stub_methods(Assistant::Config, enabled?: true) do
      stub_methods(Assistant::Context::Resolver, find: target) do
        post "/api/v1/assistant/context_previews", params: {
          references: [ { type: "target", id: "a" } ]
        }, as: :json
      end
    end

    assert_response :success
    preview = response.parsed_body.fetch("previews").sole
    assert_equal 1, preview.fetch("schema_version")
    assert_equal "target", preview.fetch("type")
    assert_equal "a", preview.fetch("id")
    assert_equal "example.test", preview.dig("data", "host")
  end

  test "preview fails the whole request for missing invalid or excessive references" do
    stub_methods(Assistant::Config, enabled?: true) do
      stub_methods(Assistant::Context::Resolver, find: nil) do
        post "/api/v1/assistant/context_previews", params: {
          references: [ { type: "target", id: "missing" } ]
        }, as: :json
      end
    end
    assert_response :unprocessable_entity
    assert_equal "not_found", response.parsed_body.dig("errors", 0, "code")
    assert_empty response.parsed_body.fetch("previews", [])

    stub_methods(Assistant::Config, enabled?: true) do
      post "/api/v1/assistant/context_previews", params: {
        references: 11.times.map { |index| { type: "target", id: index.to_s } }
      }, as: :json
    end
    assert_response :bad_request
    assert_equal "too_many_references", response.parsed_body["error"]
  end

  test "context endpoints obey session administration and the kill switch" do
    stub_methods(Assistant::Config, enabled?: false) do
      get "/api/v1/assistant/context_options", params: { type: "target", q: "x" }
    end
    assert_response :service_unavailable

    sign_out
    get "/api/v1/assistant/context_options", params: { type: "target", q: "x" }
    assert_response :unauthorized
  end
end
