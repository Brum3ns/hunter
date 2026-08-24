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
    Assistant::Config.define_singleton_method(:enabled?) { |*, **| true }
    Assistant::Setting.instance.enable!
    Assistant::Setting.instance.enable_control_center_write!
    _identity, @service_token = Assistant::ServiceIdentity.generate!(
      name: "cc-templates-create-#{SecureRandom.hex(4)}", role: "mcp_reader"
    )
  end

  teardown do
    Assistant::Config.define_singleton_method(:enabled?, @original_config_enabled)
  end

  test "creates a valid cmdscript template with an unrestricted command" do
    post "/api/v1/assistant/machine/control_center/templates",
      params: { template: VALID_TEMPLATE }, headers: headers(write_grant), as: :json

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
    assert_equal assistant_turns(:created).id, event.turn_id
    assert_equal assistant_turns(:created).conversation_id, event.conversation_id
    assert_equal assistant_turns(:created).provider_profile_id, event.provider_profile_id
    assert_operator event.byte_count, :>, 0
  end

  test "an audit failure rolls back the artifact create" do
    grant = write_grant
    grant_record = Assistant::TurnGrant.order(:id).last
    assert_no_difference -> { ControlCenter::Template.count } do
      assert_raises RuntimeError do
        stub_methods(Assistant::Audit, record!: ->(**) { raise "audit unavailable" }) do
          post "/api/v1/assistant/machine/control_center/templates",
            params: { template: VALID_TEMPLATE }, headers: headers(grant), as: :json
        end
      end
    end
    assert_equal 0, grant_record.reload.reserved_bytes
  end

  test "an unexpected persistence failure releases the result reservation" do
    grant = write_grant
    grant_record = Assistant::TurnGrant.order(:id).last

    assert_raises RuntimeError do
      stub_methods(ControlCenter::Templates::Persist,
        call: ->(**) { raise "persistence unavailable" }) do
        post "/api/v1/assistant/machine/control_center/templates",
          params: { template: VALID_TEMPLATE }, headers: headers(grant), as: :json
      end
    end

    assert_equal 0, grant_record.reload.reserved_bytes
  end

  test "creates a natural minimal command and preserves full safe template fields" do
    post "/api/v1/assistant/machine/control_center/templates", params: {
      template: {
        name: "httpx-file-proof", kind: "cmdscript", tags: [ "recon" ], output: "jsonl",
        commands: [ { command: "httpx" } ],
        target: { type: "file", separator: "newline", output: "__TARGET_FILE__" }
      }
    }, headers: headers(write_grant), as: :json

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
        params: { template: body }, headers: headers(write_grant), as: :json
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
        params: { template: body }, headers: headers(write_grant), as: :json
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
        params: { template: VALID_TEMPLATE }, headers: headers(write_grant), as: :json
    end

    assert_response :conflict
    assert_equal "conflict", response.parsed_body["error"]
    event = Assistant::AuditEvent.where(event: "machine.create_rejected").order(:id).last
    assert_equal "machine.create_rejected", event.event
    assert_equal({
      "operation" => "create_whiterabbit_template", "outcome" => "rejected", "reason" => "conflict"
    }, event.metadata)
  end

  test "refuses a grant without the write scope" do
    grant = write_grant
    Assistant::TurnGrant.order(:id).last.update_column(:write_scopes, [])

    assert_no_difference -> { ControlCenter::Template.count } do
      post "/api/v1/assistant/machine/control_center/templates",
        params: { template: VALID_TEMPLATE }, headers: headers(grant), as: :json
    end

    assert_response :forbidden
    assert_equal "scope_not_granted", response.parsed_body["error"]
  end

  test "a committed create still returns 201 even when the byte budget is exhausted at completion" do
    grant = write_grant
    record = Assistant::TurnGrant.order(:id).last
    # Shrink the per-call byte budget below the (small, fixed) create
    # response so completion sees a byte_limit overrun even though the
    # budget pre-check at authorize time passed. This simulates the byte
    # gate firing at completion time for an already-committed write.
    record.update_column(:max_result_bytes, 1)

    assert_difference -> { ControlCenter::Template.count }, 1 do
      post "/api/v1/assistant/machine/control_center/templates",
        params: { template: VALID_TEMPLATE }, headers: headers(grant), as: :json
    end

    assert_response :created
    body = response.parsed_body
    receipt = body.fetch("receipt")
    assert receipt.dig("target", "id").present?
    assert ControlCenter::Template.exists?(receipt.dig("target", "id"))

    record.reload
    assert_not_nil record.revoked_at
    assert Assistant::AuditEvent.exists?(event: "grant.result_rejected", status: "rejected")
  end

  test "refuses to create when the control center write toggle is off" do
    # Toggle-off is a runtime re-check on an already-issued grant (the Issuer
    # already excludes the create tool for grants issued *after* the toggle
    # flips off; this exercises the other half of the double gate — a grant
    # issued while the toggle was on, used after it flips off).
    grant = write_grant
    Assistant::Setting.instance.disable_control_center_write!(user: machine_user)

    assert_no_difference -> { ControlCenter::Template.count } do
      post "/api/v1/assistant/machine/control_center/templates",
        params: { template: VALID_TEMPLATE }, headers: headers(grant), as: :json
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

  def write_grant
    Assistant::Grants::Issuer.call(
      turn: assistant_turns(:created),
      resources: [],
      tools: [ "create_whiterabbit_template" ]
    )
  end

  def headers(grant)
    { "Authorization" => "Bearer #{@service_token}", "X-Hunter-Turn-Grant" => grant }
  end
end
