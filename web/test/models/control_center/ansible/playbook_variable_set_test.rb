require "test_helper"

class ControlCenter::Ansible::PlaybookVariableSetTest < ActiveSupport::TestCase
  test "a variable set can only be attached once to a playbook" do
    playbook = ControlCenter::Ansible::Playbook.create!(
      name: "Baseline", yaml_content: "---\n- hosts: workers\n  tasks: []\n", created_by: users(:one)
    )
    set = ControlCenter::Ansible::VariableSet.create!(name: "Production", created_by: users(:one))
    playbook.playbook_variable_sets.create!(variable_set: set, position: 0)

    duplicate = playbook.playbook_variable_sets.build(variable_set: set, position: 1)

    refute duplicate.valid?
    assert_includes duplicate.errors[:variable_set_id], "has already been taken"
  end
end
