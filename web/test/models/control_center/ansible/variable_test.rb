require "test_helper"

class ControlCenter::Ansible::VariableTest < ActiveSupport::TestCase
  setup do
    @set = ControlCenter::Ansible::VariableSet.create!(name: "Production", created_by: users(:one))
  end

  test "loads a typed number from encrypted storage" do
    variable = @set.variables.create!(
      name: "deploy_port", value_type: "number", serialized_value: "8443", position: 1
    )

    assert_equal 8443, variable.typed_value
    raw = ActiveRecord::Base.connection.select_value(
      "SELECT serialized_value FROM control_center_ansible_variables WHERE id = #{variable.id.to_i}"
    )
    refute_includes raw, "8443"
  end

  test "typed value assignment stores canonical JSON" do
    variable = @set.variables.build(name: "features", value_type: "list", position: 1)

    variable.typed_value = [ "alpha", true, 2 ]
    variable.save!

    assert_equal '["alpha",true,2]', variable.serialized_value
    assert_equal [ "alpha", true, 2 ], variable.typed_value
  end

  test "name is unique within a set and follows Ansible variable syntax" do
    @set.variables.create!(name: "deploy_port", value_type: "number", serialized_value: "8443")

    duplicate = @set.variables.build(name: "deploy_port", value_type: "string", serialized_value: '"x"')
    invalid = @set.variables.build(name: "not-valid", value_type: "string", serialized_value: '"x"')

    refute duplicate.valid?
    assert_includes duplicate.errors[:name], "has already been taken"
    refute invalid.valid?
    assert invalid.errors[:name].any?
  end

  test "rejects serialized content that does not match its declared type" do
    variable = @set.variables.build(name: "enabled", value_type: "boolean", serialized_value: '"true"')

    refute variable.valid?
    assert_includes variable.errors[:serialized_value], "must be a boolean"
  end

  test "rejects reserved connection secret names case insensitively" do
    %w[Ansible_Password ansible_connection].each do |name|
      variable = @set.variables.build(
        name: name, value_type: "string", serialized_value: '"secret"'
      )

      refute variable.valid?
      assert_includes variable.errors[:name], "is reserved for connection credentials"
    end
  end
end
