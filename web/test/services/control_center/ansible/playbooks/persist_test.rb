require "test_helper"

class ControlCenter::Ansible::Playbooks::PersistTest < ActiveSupport::TestCase
  YAML = "---\n- hosts: workers\n  tasks: []\n"

  test "creates with server-side creator and preserves variable set order" do
    first = variable_set("First")
    second = variable_set("Second")
    record = ControlCenter::Ansible::Playbook.new

    result = ControlCenter::Ansible::Playbooks::Persist.call(
      record: record,
      attributes: {
        name: "Baseline", yaml_content: YAML,
        variable_set_ids: [ second.id, first.id ], created_by_id: users(:two).id
      },
      user: users(:one)
    )

    assert result.success?, result.errors.to_hash.inspect
    assert_equal users(:one), record.created_by
    assert_equal [ second.id, first.id ], record.reload.variable_sets.map(&:id)
  end

  test "preserves the record and joins when model validation fails" do
    first = variable_set("First")
    second = variable_set("Second")
    record = ControlCenter::Ansible::Playbook.create!(
      name: "Baseline", yaml_content: YAML, created_by: users(:one)
    )
    record.playbook_variable_sets.create!(variable_set: first, position: 0)

    result = ControlCenter::Ansible::Playbooks::Persist.call(
      record: record,
      attributes: {
        yaml_content: "---\n- hosts: workers\n  connection: local\n",
        variable_set_ids: [ second.id ]
      },
      user: users(:one)
    )

    refute result.success?
    assert_includes result.errors[:yaml_content], "connection: local is not allowed"
    record.reload
    assert_equal YAML, record.yaml_content
    assert_equal [ first.id ], record.variable_sets.map(&:id)
  end

  test "rejects unknown duplicate and stale destination references" do
    first = variable_set("First")
    record = ControlCenter::Ansible::Playbook.create!(
      name: "Baseline", yaml_content: YAML, created_by: users(:one)
    )

    duplicate = ControlCenter::Ansible::Playbooks::Persist.call(
      record: record,
      attributes: { variable_set_ids: [ first.id, first.id ] },
      user: users(:one)
    )
    refute duplicate.success?
    assert_includes duplicate.errors[:variable_set_ids], "must contain unique integer IDs"

    reviewed_version = record.reload.lock_version
    ControlCenter::Ansible::Playbook.find(record.id).update!(description: "Concurrent edit")
    stale = ControlCenter::Ansible::Playbooks::Persist.call(
      record: record,
      attributes: { description: "Assistant edit" },
      user: users(:one),
      expected_lock_version: reviewed_version
    )
    refute stale.success?
    assert_includes stale.errors[:base], "destination_stale"
    assert_equal "Concurrent edit", record.reload.description
  end

  private

  def variable_set(name)
    ControlCenter::Ansible::VariableSet.create!(name: name, created_by: users(:one))
  end
end
