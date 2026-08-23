require "test_helper"

class Api::V1::Assistant::Machine::ControlCenter::Ansible::ResourcesTest < ActionDispatch::IntegrationTest
  setup do
    @original_config_enabled = Assistant::Config.method(:enabled?)
    Assistant::Config.define_singleton_method(:enabled?) { |*, **| true }
    Assistant::Setting.instance.enable!
    Assistant::Setting.instance.update!(control_center_write_enabled: true)
    _identity, @service_token = Assistant::ServiceIdentity.generate!(
      name: "ansible-resources-#{SecureRandom.hex(4)}", role: "mcp_reader"
    )
  end

  teardown do
    Assistant::Config.define_singleton_method(:enabled?, @original_config_enabled)
  end

  test "credential tools expose metadata but never encrypted authentication material" do
    credential = ControlCenter::Ansible::Credential.new(
      name: "prod", auth_type: "password", username: "deploy", ssh_password: "super-secret",
      created_by: machine_user, public_key_fingerprint: "SHA256:public"
    )
    credential.save!(validate: false)

    get "/api/v1/assistant/machine/control_center/ansible/credentials/#{credential.id}",
      headers: headers(grant("get_ansible_credential_metadata"))

    assert_response :success
    metadata = response.parsed_body.fetch("credential")
    assert_equal "prod", metadata.fetch("name")
    assert_equal true, metadata.fetch("ssh_password_configured")
    refute_includes response.body, "super-secret"
    refute metadata.key?("ssh_password")
  end

  test "creates and version-edits a validated inventory with receipts" do
    yaml = "all:\n  hosts:\n    web.example.test:\n      ansible_host: 192.0.2.10\n"
    post "/api/v1/assistant/machine/control_center/ansible/inventories",
      params: { inventory: { name: "prod", description: "Production", yaml_content: yaml,
        variable_set_ids: [] } }, headers: headers(grant("create_ansible_inventory")), as: :json

    assert_response :created
    inventory = ControlCenter::Ansible::Inventory.find(response.parsed_body.dig("receipt", "target", "id"))
    assert_equal machine_user, inventory.created_by
    assert_equal 0, inventory.lock_version

    patch "/api/v1/assistant/machine/control_center/ansible/inventories/#{inventory.id}",
      params: { expected_lock_version: 0, changes: { description: "Updated" } },
      headers: headers(grant("edit_ansible_inventory")), as: :json
    assert_response :success
    assert_equal "Updated", inventory.reload.description
    assert_equal 1, inventory.lock_version
  end

  test "creates variable sets and only nonsecret variables" do
    post "/api/v1/assistant/machine/control_center/ansible/variable_sets",
      params: { variable_set: { name: "scan", description: "Scanner values" } },
      headers: headers(grant("create_ansible_variable_set")), as: :json
    assert_response :created
    set = ControlCenter::Ansible::VariableSet.find(response.parsed_body.dig("receipt", "target", "id"))

    post "/api/v1/assistant/machine/control_center/ansible/variable_sets/#{set.id}/variables",
      params: { variable: { name: "threads", value_type: "number", value: 20, position: 0 } },
      headers: headers(grant("create_nonsecret_ansible_variable")), as: :json
    assert_response :created
    variable = set.variables.reload.sole
    assert_equal 20, variable.typed_value
    assert_equal false, variable.secret?

    post "/api/v1/assistant/machine/control_center/ansible/variable_sets/#{set.id}/variables",
      params: { variable: { name: "api_token", value_type: "string", value: "not-allowed", position: 1 } },
      headers: headers(grant("create_nonsecret_ansible_variable")), as: :json
    assert_response :unprocessable_content
    assert_equal 1, set.variables.reload.count
  end

  test "launch and cancel use domain services and return effect receipts" do
    group = Struct.new(:id).new(42)
    captured = nil
    launch = {
      playbook_id: 1, inventory_id: 2, credential_id: 3,
      variable_set_ids: [], overrides: [ { name: "threads", value_type: "number", value: 10 } ],
      host_limit: "web", check_mode: true, timeout_seconds: 600
    }
    stub_methods(ControlCenter::Ansible::SingleLaunch, call: ->(**args) { captured = args; group }) do
      post "/api/v1/assistant/machine/control_center/ansible/run_groups", params: launch,
        headers: headers(grant("launch_ansible_run_group")), as: :json
    end
    assert_response :created
    assert_equal machine_user, captured.fetch(:user)
    assert_equal 42, response.parsed_body.dig("receipt", "target", "id").to_i

    stub_methods(ControlCenter::Ansible::RunCancellation, cancel_group!: group) do
      stub_methods(ControlCenter::Ansible::RunGroup, find_by: group) do
        post "/api/v1/assistant/machine/control_center/ansible/run_groups/42/cancel",
          headers: headers(grant("cancel_ansible_run_group")), as: :json
      end
    end
    assert_response :success
    assert_equal "cancelled", response.parsed_body.dig("receipt", "status")
  end

  private

  def machine_user
    assistant_turns(:created).user
  end

  def grant(tool)
    Assistant::Grants::Issuer.call(turn: assistant_turns(:created), resources: [], tools: [ tool ])
  end

  def headers(raw_grant)
    { "Authorization" => "Bearer #{@service_token}", "X-Hunter-Turn-Grant" => raw_grant }
  end
end
