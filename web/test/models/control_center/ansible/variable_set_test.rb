require "test_helper"

class ControlCenter::Ansible::VariableSetTest < ActiveSupport::TestCase
  test "normalizes its name and enforces case-insensitive uniqueness" do
    set = ControlCenter::Ansible::VariableSet.create!(name: "  Production  ", created_by: users(:one))
    duplicate = ControlCenter::Ansible::VariableSet.new(name: "production", created_by: users(:one))

    assert_equal "Production", set.name
    refute duplicate.valid?
    assert_includes duplicate.errors[:name], "has already been taken"
  end

  test "variables are ordered by position and id" do
    set = ControlCenter::Ansible::VariableSet.create!(name: "Production", created_by: users(:one))
    set.variables.create!(name: "last", value_type: "string", serialized_value: '"last"', position: 2)
    set.variables.create!(name: "first", value_type: "string", serialized_value: '"first"', position: 1)

    assert_equal %w[first last], set.reload.variables.map(&:name)
  end
end
