require "test_helper"

class ControlCenter::Ansible::PlaybookTest < ActiveSupport::TestCase
  YAML = "---\n- hosts: workers\n  tasks: []\n"

  test "normalizes its name and calculates a content checksum" do
    playbook = ControlCenter::Ansible::Playbook.create!(
      name: "  Baseline  ", yaml_content: YAML, created_by: users(:one)
    )

    assert_equal "Baseline", playbook.name
    assert_equal Digest::SHA256.hexdigest(YAML), playbook.checksum
  end

  test "name is unique case insensitively" do
    ControlCenter::Ansible::Playbook.create!(name: "Baseline", yaml_content: YAML, created_by: users(:one))

    duplicate = ControlCenter::Ansible::Playbook.new(
      name: "baseline", yaml_content: YAML, created_by: users(:one)
    )

    refute duplicate.valid?
    assert_includes duplicate.errors[:name], "has already been taken"
  end

  test "rejects playbooks that can execute on the control plane" do
    playbook = ControlCenter::Ansible::Playbook.new(
      name: "Unsafe", yaml_content: "---\n- hosts: workers\n  connection: local\n  tasks: []\n", created_by: users(:one)
    )

    refute playbook.valid?
    assert_includes playbook.errors[:yaml_content], "connection: local is not allowed"
  end

  test "default variable sets are ordered by join position" do
    playbook = ControlCenter::Ansible::Playbook.create!(
      name: "Baseline", yaml_content: YAML, created_by: users(:one)
    )
    later = ControlCenter::Ansible::VariableSet.create!(name: "Later", created_by: users(:one))
    earlier = ControlCenter::Ansible::VariableSet.create!(name: "Earlier", created_by: users(:one))
    playbook.playbook_variable_sets.create!(variable_set: later, position: 2)
    playbook.playbook_variable_sets.create!(variable_set: earlier, position: 1)

    assert_equal [ "Earlier", "Later" ], playbook.reload.variable_sets.map(&:name)
  end
end
