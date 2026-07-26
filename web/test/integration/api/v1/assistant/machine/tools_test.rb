require "test_helper"

class Api::V1::Assistant::Machine::ToolsTest < ActionDispatch::IntegrationTest
  setup do
    # Activation is now derived from provider credential files, not this env
    # var, so stub Config.enabled? directly to simulate an installed key.
    @original_config_enabled = Assistant::Config.method(:enabled?)
    Assistant::Config.define_singleton_method(:enabled?) { |*, **| true }
    Assistant::Setting.instance.enable!
    _identity, @service_token = Assistant::ServiceIdentity.generate!(
      name: "tools-#{SecureRandom.hex(4)}", role: "mcp_reader"
    )
  end

  teardown do
    Assistant::Config.define_singleton_method(:enabled?, @original_config_enabled)
  end

  test "grant introspection returns safe scope and remaining budgets" do
    grant_token = issue_grant

    get "/api/v1/assistant/machine/grant", headers: headers(grant_token)

    assert_response :success
    body = response.parsed_body
    assert_equal assistant_turns(:created).correlation_id, body["correlation_id"]
    assert_equal [ "get_selected_context" ], body["tools"]
    assert_equal [ { "type" => "target", "id" => "abc" } ], body["resources"]
    assert body["calls_remaining"].positive?
    refute_includes response.body, grant_token
    refute_includes response.body, "token_digest"
  end

  test "exact context fetch completes a reservation and returns budget headers" do
    target = Target.new("id" => "abc", "target" => { "host" => "example.test" })

    stub_methods(Assistant::Context::Resolver, find: target) do
      get "/api/v1/assistant/machine/contexts/target/abc", headers: headers(issue_grant)
    end

    assert_response :success
    assert_equal "example.test", response.parsed_body.dig("context", "data", "host")
    assert response.headers["X-Hunter-Grant-Calls-Remaining"].present?
    assert response.headers["X-Hunter-Grant-Bytes-Remaining"].present?
    grant = Assistant::TurnGrant.order(:id).last
    assert_equal 1, grant.call_count
    assert_operator grant.returned_bytes, :positive?
    assert_equal 0, grant.reserved_bytes
  end

  test "an arbitrary resource ID is denied before resolution" do
    resolved = false

    stub_methods(Assistant::Context::Resolver, find: ->(**) { resolved = true }) do
      get "/api/v1/assistant/machine/contexts/target/other", headers: headers(issue_grant)
    end

    assert_response :forbidden
    assert_equal "resource_not_allowed", response.parsed_body["reason"]
    refute resolved
  end

  test "grant call limits prevent replay" do
    grant_token = issue_grant
    Assistant::TurnGrant.order(:id).last.update_column(:max_calls, 1)
    target = Target.new("id" => "abc", "target" => { "host" => "example.test" })

    stub_methods(Assistant::Context::Resolver, find: target) do
      get "/api/v1/assistant/machine/contexts/target/abc", headers: headers(grant_token)
      assert_response :success
      get "/api/v1/assistant/machine/contexts/target/abc", headers: headers(grant_token)
    end

    assert_response :forbidden
    assert_equal "grant_calls_exhausted", response.parsed_body["reason"]
  end

  test "artifact fetch rejects secret-bearing examples without returning content" do
    template = ControlCenter::Template.new(
      name: "Secret", kind: "cmdscript",
      commands: [ { command: "httpx", args: [ "--token=private" ], operator: "" } ]
    )
    grant_token = Assistant::Grants::Issuer.call(
      turn: assistant_turns(:created),
      resources: [ { type: "whiterabbit_template", id: "7" } ],
      tools: [ "get_artifact_example" ]
    )

    stub_methods(Assistant::Context::Resolver, find: template) do
      get "/api/v1/assistant/machine/artifacts/whiterabbit_template/7",
        headers: headers(grant_token)
    end

    assert_response :unprocessable_entity
    assert_equal "unsafe_content", response.parsed_body["error"]
    refute_includes response.body, "private"
    assert_equal 0, Assistant::TurnGrant.order(:id).last.reserved_bytes
  end

  test "policy and Whiterabbit validation are closed and do not persist or execute" do
    grant_token = Assistant::Grants::Issuer.call(
      turn: assistant_turns(:created), resources: [],
      tools: [ "get_authoring_policy", "validate_whiterabbit_draft" ]
    )

    stub_methods(ControlCenter::TemplateValidator, allowlist: [ "httpx" ]) do
      get "/api/v1/assistant/machine/policies/whiterabbit_template",
        headers: headers(grant_token)
      assert_response :success
      assert_equal 1, response.parsed_body.dig("policy", "schema_version")
      assert_equal [ "httpx" ], response.parsed_body.dig("policy", "command_allowlist")
      refute_includes response.body, "secret_ref"

      assert_no_difference -> { ControlCenter::Template.count } do
        post "/api/v1/assistant/machine/validations/whiterabbit_template",
          params: {
            draft: {
              name: "x", kind: "cmdscript", description: "",
              commands: [ { command: "httpx", args: [], operator: "" } ]
            }
          }, headers: headers(grant_token), as: :json
      end
    end
    assert_response :success
    assert_equal assistant_turns(:created).correlation_id, response.parsed_body["correlation_id"]
    assert_equal "valid", response.parsed_body.dig("validation", "status")
    assert_equal "whiterabbit-v1", response.parsed_body.dig("validation", "version")
    assert_equal "x", response.parsed_body.dig("validation", "normalized", "name")
  end

  test "Ansible validation is statically checked then retrieved only through its issuing grant" do
    source = <<~YAML
      ---
      - hosts: workers
        gather_facts: false
        tasks:
          - ansible.builtin.debug:
              msg: ready
    YAML
    grant_token = Assistant::Grants::Issuer.call(
      turn: assistant_turns(:created), resources: [],
      tools: [ "validate_ansible_draft", "get_validation_result" ]
    )
    original_allowlist = ENV["ASSISTANT_ANSIBLE_MODULE_ALLOWLIST"]
    ENV["ASSISTANT_ANSIBLE_MODULE_ALLOWLIST"] = "ansible.builtin.debug"
    published = nil

    stub_methods(Assistant::Broker, publish: ->(**attributes) { published = attributes; true }) do
      post "/api/v1/assistant/machine/validations/ansible_playbook",
        params: { draft: { name: "Check", source: source } },
        headers: headers(grant_token), as: :json
    end

    assert_response :accepted
    validation_id = response.parsed_body.dig("validation", "id")
    assert validation_id.present?
    assert_equal "pending", response.parsed_body.dig("validation", "status")
    assert_equal validation_id, published.dig(:body, "validation_id")

    Assistant::ValidationDispatcher.ingest!({
      "schema_version" => 1,
      "event_id" => SecureRandom.uuid,
      "validation_id" => validation_id,
      "correlation_id" => assistant_turns(:created).correlation_id,
      "status" => "valid",
      "codes" => []
    })
    get "/api/v1/assistant/machine/validation_results/#{validation_id}",
      headers: headers(grant_token)

    assert_response :success
    assert_equal "valid", response.parsed_body.dig("validation", "status")
    assert_equal source, response.parsed_body.dig("validation", "normalized", "source")
    assert_equal Digest::SHA256.hexdigest(source), response.parsed_body.dig("validation", "content_digest")
  ensure
    ENV["ASSISTANT_ANSIBLE_MODULE_ALLOWLIST"] = original_allowlist
  end

  test "Ansible static rejection is immediate and creates no validation request" do
    grant_token = Assistant::Grants::Issuer.call(
      turn: assistant_turns(:created), resources: [], tools: [ "validate_ansible_draft" ]
    )
    original_allowlist = ENV["ASSISTANT_ANSIBLE_MODULE_ALLOWLIST"]
    ENV.delete("ASSISTANT_ANSIBLE_MODULE_ALLOWLIST")

    assert_no_difference -> { Assistant::ValidationRequest.count } do
      post "/api/v1/assistant/machine/validations/ansible_playbook",
        params: { draft: { name: "Unsafe", source: "---\n- hosts: workers\n  tasks: []\n" } },
        headers: headers(grant_token), as: :json
    end

    assert_response :success
    assert_equal "invalid", response.parsed_body.dig("validation", "status")
    assert_includes response.parsed_body.dig("validation", "details", "codes"),
      "assistant_ansible_policy_unconfigured"
  ensure
    ENV["ASSISTANT_ANSIBLE_MODULE_ALLOWLIST"] = original_allowlist
  end

  private

  def issue_grant
    Assistant::Grants::Issuer.call(
      turn: assistant_turns(:created),
      resources: [ { type: "target", id: "abc" } ],
      tools: [ "get_selected_context" ]
    )
  end

  def headers(grant)
    {
      "Authorization" => "Bearer #{@service_token}",
      "X-Hunter-Turn-Grant" => grant
    }
  end
end
