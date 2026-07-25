require "test_helper"

class ControlCenter::Ansible::InventoryVariableSetTest < ActiveSupport::TestCase
  test "a variable set can only be attached once to an inventory" do
    inventory = ControlCenter::Ansible::Inventory.create!(
      name: "Workers", yaml_content: "---\nall:\n  hosts: {}\n", created_by: users(:one)
    )
    set = ControlCenter::Ansible::VariableSet.create!(name: "Production", created_by: users(:one))
    inventory.inventory_variable_sets.create!(variable_set: set, position: 0)

    duplicate = inventory.inventory_variable_sets.build(variable_set: set, position: 1)

    refute duplicate.valid?
    assert_includes duplicate.errors[:variable_set_id], "has already been taken"
  end
end
