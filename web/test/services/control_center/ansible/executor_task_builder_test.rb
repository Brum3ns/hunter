require "test_helper"

class ControlCenter::Ansible::ExecutorTaskBuilderTest < ActiveSupport::TestCase
  INVENTORY_YAML = <<~YAML
    ---
    all:
      hosts:
        worker-one:
          ansible_host: 10.10.0.8
        worker-two:
          ansible_host: 10.10.0.9
          ansible_port: 2222
  YAML

  setup do
    @user = users(:one)
    @credential = ControlCenter::Ansible::Credential.create!(
      name: "Deploy", auth_type: "password", username: "ansible",
      ssh_password: "fleet-secret", created_by: @user
    )
    @inventory = ControlCenter::Ansible::Inventory.create!(
      name: "Workers", yaml_content: INVENTORY_YAML, default_credential: @credential,
      known_hosts: "worker-one ssh-ed25519 AAAA", host_key_fingerprints: { "worker-one:22" => "SHA256:ok" },
      created_by: @user
    )
    @playbook = ControlCenter::Ansible::Playbook.create!(
      name: "Baseline", yaml_content: "---\n- hosts: all\n  tasks: []\n", created_by: @user
    )
  end

  test "defines utility task construction" do
    assert defined?(ControlCenter::Ansible::ExecutorTaskBuilder), "expected ExecutorTaskBuilder to be defined"
  end

  test "host-key scan contains normalized targets and no credential material" do
    task = ControlCenter::Ansible::ExecutorTaskBuilder.host_key_scan(
      user: @user, inventory: @inventory
    )

    assert_equal "host_key_scan", task.kind
    assert_equal [
      { "host" => "worker-one", "address" => "10.10.0.8", "port" => 22 },
      { "host" => "worker-two", "address" => "10.10.0.9", "port" => 2222 }
    ], task.execution_payload.fetch("targets")
    refute_match(/credential|password|private_key|fleet-secret/i, JSON.generate(task.execution_payload))
  end

  test "syntax check snapshots playbook inventory and non-secret execution metadata" do
    task = ControlCenter::Ansible::ExecutorTaskBuilder.syntax_check(
      user: @user, inventory: @inventory, playbook: @playbook
    )

    assert_equal "syntax_check", task.kind
    assert_equal @playbook.yaml_content, task.execution_payload["playbook_yaml"]
    assert_equal @inventory.yaml_content, task.execution_payload["inventory_yaml"]
    refute_match(/fleet-secret|password|private_key/i, JSON.generate(task.execution_payload))
  end

  test "connectivity test encrypts approved hosts and selected credential material" do
    task = ControlCenter::Ansible::ExecutorTaskBuilder.connectivity_test(
      user: @user, inventory: @inventory
    )

    assert_equal "connectivity_test", task.kind
    assert_equal "fleet-secret", task.execution_payload.dig("credential", "ssh_password")
    raw = ActiveRecord::Base.connection.select_value(<<~SQL)
      SELECT execution_payload FROM control_center_ansible_executor_tasks WHERE id = #{task.id.to_i}
    SQL
    refute_includes raw, "fleet-secret"
    assert_equal @inventory.known_hosts, task.execution_payload["known_hosts"]
  end

  test "rejects connectivity without approved hosts or a usable credential" do
    @inventory.update!(known_hosts: nil, host_key_fingerprints: {})

    error = assert_raises(ControlCenter::Ansible::ExecutorTaskBuilder::Error) do
      ControlCenter::Ansible::ExecutorTaskBuilder.connectivity_test(user: @user, inventory: @inventory)
    end

    assert_equal "inventory_unapproved", error.code
  end
end
