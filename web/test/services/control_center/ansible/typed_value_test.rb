require "test_helper"

class ControlCenter::Ansible::TypedValueTest < ActiveSupport::TestCase
  Subject = ControlCenter::Ansible::TypedValue

  test "preserves exact strings through canonical JSON" do
    serialized = Subject.dump("  001 true  ", type: "string")

    assert_equal '"  001 true  "', serialized
    assert_equal "  001 true  ", Subject.load(serialized, type: "string")
  end

  test "accepts only finite JSON-compatible numbers and literal booleans" do
    assert_equal "42.5", Subject.dump(42.5, type: "number")
    assert_equal "true", Subject.dump(true, type: "boolean")
    assert_raises(Subject::Error) { Subject.dump(Float::NAN, type: "number") }
    assert_raises(Subject::Error) { Subject.dump(Float::INFINITY, type: "number") }
    assert_raises(Subject::Error) { Subject.dump("true", type: "boolean") }
  end

  test "normalizes safe YAML and JSON list fragments" do
    yaml = Subject.dump("---\n- alpha\n- enabled: true\n", type: "list")
    json = Subject.dump('["alpha",{"enabled":true}]', type: "list")

    assert_equal '["alpha",{"enabled":true}]', yaml
    assert_equal yaml, json
  end

  test "normalizes safe YAML and JSON dictionary fragments" do
    yaml = Subject.dump("---\nname: worker\nports:\n  - 22\n  - 443\n", type: "dictionary")
    json = Subject.dump('{"name":"worker","ports":[22,443]}', type: "dictionary")

    assert_equal '{"name":"worker","ports":[22,443]}', yaml
    assert_equal yaml, json
  end

  test "rejects unsafe fragments and non-string dictionary keys recursively" do
    assert_raises(Subject::Error) do
      Subject.dump("---\ndefault: &default\n  - one\ncopy: *default\n", type: "dictionary")
    end
    assert_raises(Subject::Error) { Subject.dump("--- !custom\n- one\n", type: "list") }
    assert_raises(Subject::Error) { Subject.dump({ "outer" => { symbol: "value" } }, type: "dictionary") }
    assert_raises(Subject::Error) { Subject.dump(:symbol, type: "string") }
  end

  test "enforces typed-value depth and node limits on dump and load" do
    nested = "leaf"
    (Subject::MAX_DEPTH + 1).times { nested = [ nested ] }
    many = Array.new(Subject::MAX_NODES, 0)

    assert_raises(Subject::Error) { Subject.dump(nested, type: "list") }
    serialized = JSON.generate(many)
    assert_raises(Subject::Error) { Subject.load(serialized, type: "list") }
  end

  test "normalizes parser and declared-type errors" do
    error = assert_raises(Subject::Error) { Subject.load("not-json", type: "list") }
    mismatch = assert_raises(Subject::Error) { Subject.dump([], type: "dictionary") }

    assert_equal "must contain valid JSON", error.message
    assert_equal "must be a dictionary", mismatch.message
  end
end
