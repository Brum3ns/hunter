require "test_helper"

class Api::V1::Assistant::Machine::ControlCenter::TemplatesEditTest < ActionDispatch::IntegrationTest
  setup do
    @original_config_enabled = Assistant::Config.method(:enabled?)
    @original_admin_username = ENV["ADMIN_USERNAME"]
    ENV["ADMIN_USERNAME"] = users(:one).username
    Assistant::Config.define_singleton_method(:enabled?) { |*, **| true }
    Assistant::Setting.instance.enable!
    Assistant::Setting.instance.enable_control_center_write!
    _identity, @service_token = Assistant::ServiceIdentity.generate!(
      name: "cc-templates-edit-#{SecureRandom.hex(4)}", role: "mcp_reader"
    )
    @template = ControlCenter::Template.create!(
      name: "httpx-proof", kind: "cmdscript", description: "Original",
      commands: [ { "command" => "httpx", "args" => [ "-silent" ], "operator" => "" } ],
      created_by: machine_user.username
    )
  end

  teardown do
    Assistant::Config.define_singleton_method(:enabled?, @original_config_enabled)
    ENV["ADMIN_USERNAME"] = @original_admin_username
  end

  test "edits by ID and expected version after validating the complete merged template" do
    patch endpoint, params: {
      expected_lock_version: @template.lock_version,
      changes: { description: "Updated", commands: [ { command: "httpx" } ] }
    }, headers: headers, as: :json

    assert_response :success
    assert_equal "updated", response.parsed_body.dig("receipt", "status")
    assert_equal "Updated", @template.reload.description
    assert_equal [], @template.commands.first.fetch("args")
    assert_equal machine_user.username, @template.created_by
    assert_nil @template.output
    assert_nil @template.target
    event = Assistant::AuditEvent.where(event: "machine.edit").order(:id).last
    assert_equal "machine.edit", event.event
    assert_equal({ "operation" => "edit_whiterabbit_template", "outcome" => "updated" },
      event.metadata.slice("operation", "outcome"))
    assert_equal "token_only", event.metadata.fetch("authorization_mode")
  end

  test "edits a template to an arbitrary command" do
    patch endpoint, params: {
      expected_lock_version: @template.lock_version,
      changes: { commands: [ { command: "python", args: [ "-c", "print('ok')" ] } ] }
    }, headers: headers, as: :json

    assert_response :success
    assert_equal "python", @template.reload.commands.first.fetch("command")
  end

  test "a stale version leaves the row unchanged" do
    original = @template.attributes

    patch endpoint, params: { expected_lock_version: 99, changes: { description: "Lost" } },
      headers: headers, as: :json

    assert_response :conflict
    assert_equal "version_conflict", response.parsed_body["error"]
    assert_equal original, @template.reload.attributes
    event = Assistant::AuditEvent.order(:id).last
    assert_equal "machine.edit_rejected", event.event
    assert_equal "version_conflict", event.metadata["reason"]
    assert_equal @template.id.to_s, event.target_id
  end

  test "structurally invalid merged content leaves the row unchanged" do
    original = @template.attributes

    patch endpoint, params: {
      expected_lock_version: @template.lock_version,
      changes: { commands: [ { command: "bad\nname" } ] }
    }, headers: headers, as: :json

    assert_response :unprocessable_content
    assert_equal "validation_failed", response.parsed_body["error"]
    assert_equal original, @template.reload.attributes
  end

  test "requires the exact edit capability to remain enabled" do
    Assistant::Setting.instance.update!(
      disabled_capability_tools: [ "edit_whiterabbit_template" ]
    )
    patch endpoint, params: { expected_lock_version: 0, changes: { description: "No" } },
      headers: headers, as: :json
    assert_response :forbidden
    assert_equal "capability_disabled", response.parsed_body["error"]
    assert_equal "Original", @template.reload.description
  end

  test "an audit failure rolls back the artifact edit" do
    assert_raises RuntimeError do
      stub_methods(Assistant::Audit, record!: ->(**) { raise "audit unavailable" }) do
        patch endpoint, params: {
          expected_lock_version: @template.lock_version, changes: { description: "Must roll back" }
        }, headers: headers, as: :json
      end
    end

    assert_equal "Original", @template.reload.description
    assert_equal 0, @template.lock_version
  end

  private

  def endpoint
    "/api/v1/assistant/machine/control_center/templates/#{@template.id}"
  end

  def machine_user
    assistant_turns(:created).user
  end

  def headers(*)
    { "Authorization" => "Bearer #{@service_token}" }
  end
end
