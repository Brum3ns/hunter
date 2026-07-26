require "test_helper"

class ControlCenter::Templates::PersistTest < ActiveSupport::TestCase
  def attributes(name: "Probe")
    {
      name: name,
      kind: "cmdscript",
      description: "Safe probe",
      commands: [ { command: "httpx", args: [ "-silent" ], operator: "" } ]
    }
  end

  test "creates with server-side creator attribution and existing model validation" do
    record = ControlCenter::Template.new

    result = ControlCenter::Templates::Persist.call(
      record: record,
      attributes: attributes.merge(created_by: "forged"),
      user: users(:one)
    )

    assert result.success?, result.errors.to_hash.inspect
    assert_equal record, result.record
    assert_equal users(:one).username, record.created_by

    invalid = ControlCenter::Templates::Persist.call(
      record: ControlCenter::Template.new,
      attributes: attributes(name: "Unsafe").merge(
        commands: [ { command: "httpx", args: [ "a\nb" ], operator: "" } ]
      ),
      user: users(:one)
    )
    refute invalid.success?
    assert_includes invalid.errors[:commands].join(" "), "forbidden character"
  end

  test "updates inside a row lock and rejects a stale expected version" do
    record = ControlCenter::Template.create!(attributes)
    reviewed_version = record.lock_version
    ControlCenter::Template.find(record.id).update!(description: "Concurrent edit")

    result = ControlCenter::Templates::Persist.call(
      record: record,
      attributes: { description: "Assistant edit" },
      user: users(:one),
      expected_lock_version: reviewed_version
    )

    refute result.success?
    assert_includes result.errors[:base], "destination_stale"
    assert_equal "Concurrent edit", record.reload.description
  end
end
