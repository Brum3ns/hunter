require "test_helper"

class Assistant::Machine::ControlCenter::ArtifactInputTest < ActiveSupport::TestCase
  test "normalizes a minimal Whiterabbit create and fills command defaults" do
    input = {
      "name" => "httpx-proof", "kind" => "cmdscript",
      "commands" => [ { "command" => "httpx" } ]
    }

    result = Assistant::Machine::ControlCenter::ArtifactInput.whiterabbit_create(input)

    assert result.valid?, result.codes.inspect
    assert_equal [], result.normalized.dig("commands", 0, "args")
    assert_equal "", result.normalized.dig("commands", 0, "operator")
    assert_equal "", result.normalized["description"]
    assert_equal({ "command" => "httpx" }, input["commands"][0])
  end

  test "preserves every bounded safe Whiterabbit field and rejects unknown nested fields" do
    input = {
      name: "httpx-proof", kind: "cmdscript", tags: [ "recon" ],
      description: "Probe", output: "jsonl",
      commands: [ { command: "httpx", args: [ "-l", "__TARGET_FILE__" ], operator: "" } ],
      target: { type: "file", separator: "newline", output: "__TARGET_FILE__" }
    }
    result = Assistant::Machine::ControlCenter::ArtifactInput.whiterabbit_create(input)
    assert result.valid?, result.codes.inspect
    assert_equal [ "recon" ], result.normalized["tags"]
    assert_equal "file", result.normalized.dig("target", "type")

    invalid = Assistant::Machine::ControlCenter::ArtifactInput.whiterabbit_create(
      input.deep_merge(target: { credential: "nope" })
    )
    refute invalid.valid?
    assert_includes invalid.codes, "whiterabbit_target_unknown_field"
  end

  test "Whiterabbit changes are closed nonempty and do not mutate their input" do
    input = { "commands" => [ { "command" => "httpx" } ] }
    before = input.deep_dup
    result = Assistant::Machine::ControlCenter::ArtifactInput.whiterabbit_changes(input)
    assert result.valid?, result.codes.inspect
    assert_equal before, input
    assert_equal [], result.normalized.dig("commands", 0, "args")

    refute Assistant::Machine::ControlCenter::ArtifactInput.whiterabbit_changes({}).valid?
    refute Assistant::Machine::ControlCenter::ArtifactInput.whiterabbit_changes("description" => "x", "delete" => true).valid?
  end

  test "normalizes full Ansible create and partial changes" do
    create = Assistant::Machine::ControlCenter::ArtifactInput.ansible_create(
      "name" => "facts", "description" => "Safe", "source" => "---\n- hosts: all\n",
      "variable_set_ids" => [ 2, 3 ]
    )
    assert create.valid?, create.codes.inspect
    assert_equal [ 2, 3 ], create.normalized["variable_set_ids"]

    changes = Assistant::Machine::ControlCenter::ArtifactInput.ansible_changes(
      "description" => "Updated"
    )
    assert changes.valid?, changes.codes.inspect
    assert_equal({ "description" => "Updated" }, changes.normalized)

    duplicate = Assistant::Machine::ControlCenter::ArtifactInput.ansible_changes(
      "variable_set_ids" => [ 2, 2 ]
    )
    refute duplicate.valid?
  end

  test "rejects secret-bearing optional metadata" do
    result = Assistant::Machine::ControlCenter::ArtifactInput.whiterabbit_create(
      "name" => "proof", "kind" => "cmdscript", "description" => "token=do-not-save",
      "commands" => [ { "command" => "httpx" } ]
    )
    refute result.valid?
    assert_includes result.codes, "artifact_secret_material_not_allowed"
  end
end
