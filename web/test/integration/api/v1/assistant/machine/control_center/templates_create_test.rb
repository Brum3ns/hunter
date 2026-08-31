require "test_helper"

class Api::V1::Assistant::Machine::ControlCenter::TemplatesCreateTest < ActionDispatch::IntegrationTest
  VALID_TEMPLATE = {
    name: "assistant-probe",
    kind: "cmdscript",
    description: "Probe selected targets",
    commands: [ { command: "nuclei", args: [ "-s", "__TARGET_FILE__" ], operator: "" } ]
  }.freeze

  setup do
    @original_config_enabled = Assistant::Config.method(:enabled?)
    @original_admin_username = ENV["ADMIN_USERNAME"]
    ENV["ADMIN_USERNAME"] = users(:one).username
    Assistant::Config.define_singleton_method(:enabled?) { |*, **| true }
    Assistant::Setting.instance.enable!
    Assistant::Setting.instance.enable_control_center_write!
    _identity, @service_token = Assistant::ServiceIdentity.generate!(
      name: "cc-templates-create-#{SecureRandom.hex(4)}", role: "mcp_reader"
    )
  end

  teardown do
    Assistant::Config.define_singleton_method(:enabled?, @original_config_enabled)
    ENV["ADMIN_USERNAME"] = @original_admin_username
  end

  test "creates a valid cmdscript template with an unrestricted command" do
    post "/api/v1/assistant/machine/control_center/templates",
      params: { template: VALID_TEMPLATE }, headers: headers, as: :json

    assert_response :created
    body = response.parsed_body
    assert body["correlation_id"].present?
    receipt = body.fetch("receipt")
    assert_equal "create_whiterabbit_template", receipt.fetch("tool")
    assert_equal "created", receipt.fetch("status")

    record = ControlCenter::Template.find(receipt.dig("target", "id"))
    assert_equal "assistant-probe", record.name
    assert_equal machine_user.username, record.created_by

    event = Assistant::AuditEvent.where(event: "machine.create").order(:id).last
    assert_equal "machine.create", event.event
    assert_equal "create_whiterabbit_template", event.metadata["operation"]
    assert_equal machine_user.id, event.user_id
    assert_nil event.turn_id
    assert_nil event.conversation_id
    assert_nil event.provider_profile_id
    assert_equal "token_only", event.metadata.fetch("authorization_mode")
    assert_operator event.byte_count, :>, 0
  end

  test "an audit failure rolls back the artifact create" do
    assert_no_difference -> { ControlCenter::Template.count } do
      assert_raises RuntimeError do
        stub_methods(Assistant::Audit, record!: ->(**) { raise "audit unavailable" }) do
          post "/api/v1/assistant/machine/control_center/templates",
            params: { template: VALID_TEMPLATE }, headers: headers, as: :json
        end
      end
    end
  end

  test "an unexpected persistence failure releases the result reservation" do

    assert_raises RuntimeError do
      stub_methods(ControlCenter::Templates::Persist,
        call: ->(**) { raise "persistence unavailable" }) do
        post "/api/v1/assistant/machine/control_center/templates",
          params: { template: VALID_TEMPLATE }, headers: headers, as: :json
      end
    end

  end

  test "creates a natural minimal command and preserves full safe template fields" do
    post "/api/v1/assistant/machine/control_center/templates", params: {
      template: {
        name: "httpx-file-proof", kind: "cmdscript", tags: [ "recon" ], output: "jsonl",
        commands: [ { command: "httpx" } ],
        target: { type: "file", separator: "newline", output: "__TARGET_FILE__" }
      }
    }, headers: headers, as: :json

    assert_response :created
    record = ControlCenter::Template.find(response.parsed_body.dig("receipt", "target", "id"))
    assert_equal [], record.commands.first.fetch("args")
    assert_equal "", record.commands.first.fetch("operator")
    assert_equal [ "recon" ], record.tags
    assert_equal "file", record.target.fetch("type")
  end

  test "creates an unrestricted canary command and keeps command content out of metadata audit" do
    original = ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"]
    ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"] = "httpx"
    executable_canary = "future-executable-audit-canary-7f3c1e"
    argument_canary = "--audit-argument-canary=9d72b4"
    body = VALID_TEMPLATE.deep_dup
    body[:name] = "assistant-unrestricted-canary-proof"
    body[:commands] = [
      { command: executable_canary, args: [ argument_canary ], operator: "" }
    ]

    assert_difference -> { ControlCenter::Template.count }, 1 do
      post "/api/v1/assistant/machine/control_center/templates",
        params: { template: body }, headers: headers, as: :json
    end

    assert_response :created
    record = ControlCenter::Template.find(response.parsed_body.dig("receipt", "target", "id"))
    assert_equal executable_canary, record.commands.first.fetch("command")
    assert_equal [ argument_canary ], record.commands.first.fetch("args")
    audit = Assistant::AuditEvent.where(event: "machine.create").order(:id).last
    serialized_audit = audit.attributes.to_json
    refute_includes serialized_audit, executable_canary
    refute_includes serialized_audit, argument_canary
  ensure
    ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"] = original
  end

  test "rejects a structurally invalid command name and persists nothing" do
    body = VALID_TEMPLATE.deep_dup
    body[:commands] = [ { command: "bad\nname", args: [], operator: "" } ]

    assert_no_difference -> { ControlCenter::Template.count } do
      post "/api/v1/assistant/machine/control_center/templates",
        params: { template: body }, headers: headers, as: :json
    end

    assert_response :unprocessable_content
    assert_equal "validation_failed", response.parsed_body["error"]
  end

  test "rejects a duplicate name and does not create a second row" do
    ControlCenter::Template.create!(
      name: "assistant-probe", kind: "cmdscript", description: "existing",
      commands: [ { "command" => "nuclei", "args" => [] } ]
    )

    assert_no_difference -> { ControlCenter::Template.count } do
      post "/api/v1/assistant/machine/control_center/templates",
        params: { template: VALID_TEMPLATE }, headers: headers, as: :json
    end

    assert_response :conflict
    assert_equal "conflict", response.parsed_body["error"]
    event = Assistant::AuditEvent.where(event: "machine.create_rejected").order(:id).last
    assert_equal "machine.create_rejected", event.event
    assert_equal({
      "operation" => "create_whiterabbit_template", "outcome" => "rejected", "reason" => "conflict"
    }, event.metadata.slice("operation", "outcome", "reason"))
    assert_equal "token_only", event.metadata.fetch("authorization_mode")
  end

  test "refuses create when the exact capability is disabled" do
    Assistant::Setting.instance.update!(
      disabled_capability_tools: [ "create_whiterabbit_template" ]
    )

    assert_no_difference -> { ControlCenter::Template.count } do
      post "/api/v1/assistant/machine/control_center/templates",
        params: { template: VALID_TEMPLATE }, headers: headers, as: :json
    end

    assert_response :forbidden
    assert_equal "capability_disabled", response.parsed_body["error"]
  end

  test "a committed create still returns 201 when its token-only response exceeds the byte ceiling" do
    assert_difference -> { ControlCenter::Template.count }, 1 do
      stub_methods(Assistant::Config, max_result_bytes: 1) do
        post "/api/v1/assistant/machine/control_center/templates",
          params: { template: VALID_TEMPLATE }, headers: headers, as: :json
      end
    end

    assert_response :created
    body = response.parsed_body
    receipt = body.fetch("receipt")
    assert receipt.dig("target", "id").present?
    assert ControlCenter::Template.exists?(receipt.dig("target", "id"))

    assert Assistant::AuditEvent.exists?(event: "machine.result_rejected", status: "rejected")
  end

  test "refuses to create when the control center write toggle is off" do
    Assistant::Setting.instance.disable_control_center_write!(user: machine_user)

    assert_no_difference -> { ControlCenter::Template.count } do
      post "/api/v1/assistant/machine/control_center/templates",
        params: { template: VALID_TEMPLATE }, headers: headers, as: :json
    end

    assert_response :forbidden
    assert_equal "capability_disabled", response.parsed_body["error"]
    event = Assistant::AuditEvent.order(:id).last
    assert_equal "machine.create_rejected", event.event
    assert_equal "capability_disabled", event.metadata["reason"]
  end

  private

  def machine_user
    assistant_turns(:created).user
  end

  def headers(*)
    { "Authorization" => "Bearer #{@service_token}" }
  end
end
