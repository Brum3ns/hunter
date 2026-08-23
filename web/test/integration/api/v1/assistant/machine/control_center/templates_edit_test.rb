require "test_helper"

class Api::V1::Assistant::Machine::ControlCenter::TemplatesEditTest < ActionDispatch::IntegrationTest
  setup do
    @original_config_enabled = Assistant::Config.method(:enabled?)
    Assistant::Config.define_singleton_method(:enabled?) { |*, **| true }
    Assistant::Setting.instance.enable!
    Assistant::Setting.instance.enable_control_center_write!
    _identity, @service_token = Assistant::ServiceIdentity.generate!(
      name: "cc-templates-edit-#{SecureRandom.hex(4)}", role: "mcp_reader"
    )
    stub_methods(ControlCenter::TemplateValidator, allowlist: [ "httpx" ]) do
      @template = ControlCenter::Template.create!(
        name: "httpx-proof", kind: "cmdscript", description: "Original",
        commands: [ { "command" => "httpx", "args" => [ "-silent" ], "operator" => "" } ],
        created_by: machine_user.username
      )
    end
  end

  teardown do
    Assistant::Config.define_singleton_method(:enabled?, @original_config_enabled)
  end

  test "edits by ID and expected version after validating the complete merged template" do
    stub_methods(ControlCenter::TemplateValidator, allowlist: [ "httpx" ]) do
      patch endpoint, params: {
        expected_lock_version: @template.lock_version,
        changes: { description: "Updated", commands: [ { command: "httpx" } ] }
      }, headers: headers(edit_grant), as: :json

      assert_response :success
      assert_equal "updated", response.parsed_body.dig("receipt", "status")
      assert_equal "Updated", @template.reload.description
      assert_equal [], @template.commands.first.fetch("args")
    assert_equal machine_user.username, @template.created_by
    assert_nil @template.output
    assert_nil @template.target
      event = Assistant::AuditEvent.where(event: "machine.edit").order(:id).last
      assert_equal "machine.edit", event.event
      assert_equal({ "operation" => "edit_whiterabbit_template", "outcome" => "updated" }, event.metadata)
    end
  end

  test "stale version and invalid merged content leave the row unchanged" do
    original = @template.attributes
    stub_methods(ControlCenter::TemplateValidator, allowlist: [ "httpx" ]) do
      patch endpoint, params: { expected_lock_version: 99, changes: { description: "Lost" } },
        headers: headers(edit_grant), as: :json
      assert_response :conflict
      assert_equal "version_conflict", response.parsed_body["error"]
      assert_equal original, @template.reload.attributes
      event = Assistant::AuditEvent.order(:id).last
      assert_equal "machine.edit_rejected", event.event
      assert_equal "version_conflict", event.metadata["reason"]
      assert_equal @template.id.to_s, event.target_id

      patch endpoint, params: {
        expected_lock_version: @template.lock_version,
        changes: { commands: [ { command: "curl" } ] }
      }, headers: headers(edit_grant), as: :json
      assert_response :unprocessable_content
      assert_equal "validation_failed", response.parsed_body["error"]
      assert_equal original, @template.reload.attributes
    end
  end

  test "requires exact edit scope and never treats create authority as edit authority" do
    grant = edit_grant
    Assistant::TurnGrant.order(:id).last.update_column(:write_scopes, [ "control_center_templates_write" ])
    patch endpoint, params: { expected_lock_version: 0, changes: { description: "No" } },
      headers: headers(grant), as: :json
    assert_response :forbidden
    assert_equal "scope_not_granted", response.parsed_body["error"]
    assert_equal "Original", @template.reload.description
  end

  test "an audit failure rolls back the artifact edit" do
    grant = edit_grant
    grant_record = Assistant::TurnGrant.order(:id).last
    stub_methods(ControlCenter::TemplateValidator, allowlist: [ "httpx" ]) do
      assert_raises RuntimeError do
        stub_methods(Assistant::Audit, record!: ->(**) { raise "audit unavailable" }) do
          patch endpoint, params: {
            expected_lock_version: @template.lock_version, changes: { description: "Must roll back" }
          }, headers: headers(grant), as: :json
        end
      end
    end

    assert_equal "Original", @template.reload.description
    assert_equal 0, @template.lock_version
    assert_equal 0, grant_record.reload.reserved_bytes
  end

  private

  def endpoint
    "/api/v1/assistant/machine/control_center/templates/#{@template.id}"
  end

  def machine_user
    assistant_turns(:created).user
  end

  def edit_grant
    Assistant::Grants::Issuer.call(
      turn: assistant_turns(:created), resources: [], tools: [ "edit_whiterabbit_template" ]
    )
  end

  def headers(grant)
    { "Authorization" => "Bearer #{@service_token}", "X-Hunter-Turn-Grant" => grant }
  end
end
