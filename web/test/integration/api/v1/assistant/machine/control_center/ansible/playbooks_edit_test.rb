require "test_helper"

class Api::V1::Assistant::Machine::ControlCenter::Ansible::PlaybooksEditTest < ActionDispatch::IntegrationTest
  VALID_YAML = <<~YAML
    ---
    - hosts: workers
      gather_facts: false
      tasks:
        - ansible.builtin.debug:
            msg: updated
  YAML

  setup do
    @original_config_enabled = Assistant::Config.method(:enabled?)
    Assistant::Config.define_singleton_method(:enabled?) { |*, **| true }
    Assistant::Setting.instance.enable!
    Assistant::Setting.instance.enable_control_center_write!
    @original_allowlist = ENV["ASSISTANT_ANSIBLE_MODULE_ALLOWLIST"]
    ENV["ASSISTANT_ANSIBLE_MODULE_ALLOWLIST"] = "ansible.builtin.debug"
    _identity, @service_token = Assistant::ServiceIdentity.generate!(
      name: "cc-playbooks-edit-#{SecureRandom.hex(4)}", role: "mcp_reader"
    )
    @playbook = ControlCenter::Ansible::Playbook.create!(
      name: "safe-playbook", description: "Original", yaml_content: VALID_YAML,
      created_by: machine_user
    )
  end

  teardown do
    Assistant::Config.define_singleton_method(:enabled?, @original_config_enabled)
    ENV["ASSISTANT_ANSIBLE_MODULE_ALLOWLIST"] = @original_allowlist
  end

  test "edits every existing playbook by ID with optimistic locking" do
    patch endpoint, params: {
      expected_lock_version: @playbook.lock_version,
      changes: { name: "renamed-playbook", description: "Updated", source: VALID_YAML }
    }, headers: headers(edit_grant), as: :json

    assert_response :success
    assert_equal 1, response.parsed_body.dig("playbook", "lock_version")
    assert_equal "renamed-playbook", @playbook.reload.name
    assert_equal machine_user, @playbook.created_by
    event = Assistant::AuditEvent.order(:id).last
    assert_equal "machine.edit", event.event
    assert_equal "edit_ansible_playbook", event.metadata.fetch("operation")
  end

  test "a name-only edit preserves a nullable description" do
    @playbook.update_column(:description, nil)

    patch endpoint, params: {
      expected_lock_version: @playbook.lock_version,
      changes: { name: "renamed-with-null-description" }
    }, headers: headers(edit_grant), as: :json

    assert_response :success
    assert_nil @playbook.reload.description
  end

  test "stale and prohibited edits fail closed without changing the playbook" do
    original = @playbook.attributes
    patch endpoint, params: { expected_lock_version: 50, changes: { description: "Lost" } },
      headers: headers(edit_grant), as: :json
    assert_response :conflict
    assert_equal "destination_stale", response.parsed_body["error"]
    assert_equal original, @playbook.reload.attributes

    unsafe = "---\n- hosts: all\n  tasks:\n    - ansible.builtin.shell: whoami\n"
    patch endpoint, params: {
      expected_lock_version: @playbook.lock_version, changes: { source: unsafe }
    }, headers: headers(edit_grant), as: :json
    assert_response :unprocessable_content
    assert_equal "validation_failed", response.parsed_body["error"]
    assert_equal original, @playbook.reload.attributes
  end

  private

  def endpoint
    "/api/v1/assistant/machine/control_center/ansible/playbooks/#{@playbook.id}"
  end

  def machine_user
    assistant_turns(:created).user
  end

  def edit_grant
    Assistant::Grants::Issuer.call(
      turn: assistant_turns(:created), resources: [], tools: [ "edit_ansible_playbook" ]
    )
  end

  def headers(grant)
    { "Authorization" => "Bearer #{@service_token}", "X-Hunter-Turn-Grant" => grant }
  end
end
