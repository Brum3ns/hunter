require "test_helper"

class Assistant::DraftTest < ActiveSupport::TestCase
  test "content and validation details are encrypted and content is digested" do
    draft = Assistant::Draft.create!(
      conversation: assistant_conversations(:one),
      turn: assistant_turns(:created),
      artifact_type: "ansible_playbook",
      name: "Safe probe",
      content: "- hosts: localhost\n  tasks: []",
      validation_details: { "codes" => [ "schema.valid" ] },
      validation_status: "valid",
      validation_version: "v1"
    )

    row = ActiveRecord::Base.connection.select_one(
      "SELECT content, validation_details FROM assistant_drafts WHERE id = #{draft.id.to_i}"
    )
    refute_includes row.fetch("content"), "hosts"
    refute_includes row.fetch("validation_details"), "schema.valid"
    assert_equal Digest::SHA256.hexdigest(draft.content), draft.content_digest
    assert_equal({ "codes" => [ "schema.valid" ] }, draft.validation_details)
  end

  test "artifact and validation states use closed sets" do
    draft = Assistant::Draft.new(
      conversation: assistant_conversations(:one),
      turn: assistant_turns(:created),
      artifact_type: "shell_script",
      name: "Unsafe",
      content: "echo no",
      validation_details: {},
      validation_status: "trusted",
      validation_version: "v1"
    )

    refute draft.valid?
    assert_includes draft.errors[:artifact_type], "is not included in the list"
    assert_includes draft.errors[:validation_status], "is not included in the list"
  end

  test "content and conversation binding are immutable" do
    draft = Assistant::Draft.create!(
      conversation: assistant_conversations(:one),
      turn: assistant_turns(:created),
      artifact_type: "whiterabbit_template",
      name: "Probe",
      content: "commands: []",
      validation_details: {},
      validation_status: "pending",
      validation_version: "v1"
    )

    draft.content = "commands: [changed]"
    draft.conversation = assistant_conversations(:other_user)

    refute draft.valid?
    assert_includes draft.errors[:content], "cannot be changed"
    assert_includes draft.errors[:conversation], "cannot be changed"
  end
end
