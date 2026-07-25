require "test_helper"

class ControlCenter::Ansible::InventoryTest < ActiveSupport::TestCase
  YAML = "---\nall:\n  hosts:\n    worker-1:\n      ansible_host: 10.0.0.10\n"

  test "calculates its checksum and stores host-key metadata" do
    inventory = ControlCenter::Ansible::Inventory.create!(
      name: "Workers", yaml_content: YAML, known_hosts: "worker ssh-ed25519 AAAA",
      host_key_fingerprints: { "worker" => "SHA256:abc" }, created_by: users(:one)
    )

    assert_equal Digest::SHA256.hexdigest(YAML), inventory.checksum
    assert_equal({ "worker" => "SHA256:abc" }, inventory.host_key_fingerprints)
  end

  test "destroying a default credential nullifies the inventory reference" do
    credential = ControlCenter::Ansible::Credential.create!(
      name: "workers", auth_type: "password", username: "ansible",
      ssh_password: "secret", created_by: users(:one)
    )
    inventory = ControlCenter::Ansible::Inventory.create!(
      name: "Workers", yaml_content: YAML, default_credential: credential, created_by: users(:one)
    )

    credential.destroy!

    assert_nil inventory.reload.default_credential_id
  end

  test "rejects inventories that configure local connections" do
    inventory = ControlCenter::Ansible::Inventory.new(
      name: "Unsafe",
      yaml_content: "---\nall:\n  hosts:\n    control:\n      ansible_connection: local\n",
      created_by: users(:one)
    )

    refute inventory.valid?
    assert_includes inventory.errors[:yaml_content], "ansible_connection: local is not allowed"
  end

  test "default variable sets are ordered by join position" do
    inventory = ControlCenter::Ansible::Inventory.create!(
      name: "Workers", yaml_content: YAML, created_by: users(:one)
    )
    later = ControlCenter::Ansible::VariableSet.create!(name: "Later", created_by: users(:one))
    earlier = ControlCenter::Ansible::VariableSet.create!(name: "Earlier", created_by: users(:one))
    inventory.inventory_variable_sets.create!(variable_set: later, position: 2)
    inventory.inventory_variable_sets.create!(variable_set: earlier, position: 1)

    assert_equal [ "Earlier", "Later" ], inventory.reload.variable_sets.map(&:name)
  end
end
