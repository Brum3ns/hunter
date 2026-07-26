require "test_helper"

class AssistantEndToEndTest < ActionDispatch::IntegrationTest
  FIXTURE = Rails.root.join("../assistant/testdata/adversarial/provider_outputs.json").expand_path.freeze
  SELECTED_RECORD_FIXTURE = Rails.root
    .join("../assistant/testdata/adversarial/selected_records.json").expand_path.freeze

  setup do
    @admin = users(:one)
    @original_admin_username = ENV["ADMIN_USERNAME"]
    @original_assistant_enabled = ENV["ASSISTANT_ENABLED"]
    @original_command_allowlist = ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"]
    ENV["ADMIN_USERNAME"] = @admin.username
    ENV["ASSISTANT_ENABLED"] = "true"
    ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"] = "httpx"
    Assistant::Setting.instance.enable!
    sign_in_as(@admin)
  end

  teardown do
    ENV["ADMIN_USERNAME"] = @original_admin_username
    ENV["ASSISTANT_ENABLED"] = @original_assistant_enabled
    ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"] = @original_command_allowlist
  end

  test "selected context becomes a reviewed draft and only confirmation persists it" do
    provider_fixture = JSON.parse(FIXTURE.read).fetch("safe_whiterabbit_draft")
    target = Target.new("id" => "target-e2e", "target" => { "host" => "e2e.example.test" })
    delivery = nil

    post "/api/v1/assistant/conversations",
      params: { provider_profile_id: assistant_provider_profiles(:openai).id }, as: :json
    assert_response :created
    conversation_id = response.parsed_body.fetch("id")

    stub_methods(Assistant::Context::Resolver, find: target) do
      stub_methods(Assistant::Broker, publish: ->(**attributes) { delivery = attributes.deep_dup }) do
        post "/api/v1/assistant/conversations/#{conversation_id}/turns", params: {
          message: "Draft a bounded httpx probe",
          contexts: [ { type: "target", id: "target-e2e" } ]
        }, as: :json
      end
    end
    assert_response :accepted
    turn = Assistant::Turn.find(response.parsed_body.fetch("id"))
    raw_grant = delivery.dig(:body, "turn_grant")
    assert raw_grant.present?
    assert_equal [ "get_selected_context" ],
      provider_fixture.fetch("tool_calls").map { |call| call.fetch("name") }.uniq

    _identity, service_token = Assistant::ServiceIdentity.generate!(
      name: "e2e-mcp-#{SecureRandom.hex(4)}", role: "mcp_reader"
    )
    machine_session = open_session
    stub_methods(Assistant::Context::Resolver, find: target) do
      machine_session.get "/api/v1/assistant/machine/contexts/target/target-e2e", headers: {
        "Authorization" => "Bearer #{service_token}",
        "X-Hunter-Turn-Grant" => raw_grant
      }
    end
    assert_equal 200, machine_session.response.status
    assert_equal "e2e.example.test",
      machine_session.response.parsed_body.dig("context", "data", "host")

    provider_fixture.fetch("events").each do |fixture_event|
      Assistant::EventIngestor.call({
        "schema_version" => 1,
        "event_id" => SecureRandom.uuid,
        "correlation_id" => turn.correlation_id,
        "turn_id" => turn.id,
        "provider_profile_id" => turn.provider_profile_id
      }.merge(fixture_event))
    end

    draft = turn.drafts.sole
    assert_equal "completed", turn.reload.status
    assert_equal "valid", draft.validation_status
    assert_equal 0, ControlCenter::Template.count
    assert_equal 0, ControlCenter::Ansible::Playbook.count
    assert_equal 0, ControlCenter::Job.count
    assert_equal 0, ControlCenter::Ansible::Run.count

    get "/api/v1/assistant/drafts/#{draft.id}"
    assert_response :success
    review = response.parsed_body
    assert_equal true, review.fetch("can_save")

    previous_forgery_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    get root_path
    csrf_token = css_select("meta[name='csrf-token']").first["content"]

    assert_difference -> { ControlCenter::Template.count }, 1 do
      assert_no_difference [
        -> { ControlCenter::Ansible::Playbook.count },
        -> { ControlCenter::Job.count },
        -> { ControlCenter::Ansible::Run.count }
      ] do
        post "/api/v1/assistant/drafts/#{draft.id}/confirmed_save", params: {
          confirmation: {
            name: review.fetch("name"),
            content_digest: review.fetch("content_digest"),
            validation_version: review.dig("validation", "version"),
            diff_digest: review["diff_digest"],
            destination: review["destination"]
          }
        }, headers: { "X-CSRF-Token" => csrf_token }, as: :json
      end
    end
    assert_response :created
    assert_equal draft.name, ControlCenter::Template.order(:id).last.name
  ensure
    ActionController::Base.allow_forgery_protection = previous_forgery_protection unless
      previous_forgery_protection.nil?
  end

  test "adversarial selected-record fixtures have stable secret and control classifications" do
    cases = JSON.parse(SELECTED_RECORD_FIXTURE.read).fetch("cases")

    cases.each do |test_case|
      value = case test_case["generator"]
      when "oversized_string" then "x" * (Assistant::Context::SecretDetector::MAX_STRING_BYTES + 1)
      when "malformed_utf8" then "bad\xFFvalue".b.force_encoding(Encoding::UTF_8)
      else test_case.fetch("value")
      end
      actual = Assistant::Context::SecretDetector.detect(value)&.to_s
      if test_case["secret_expected"].nil?
        assert_nil actual, test_case.fetch("name")
      else
        assert_equal test_case.fetch("secret_expected"), actual, test_case.fetch("name")
      end
    end
  end
end
