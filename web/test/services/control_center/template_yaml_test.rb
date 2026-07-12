require "test_helper"

class ControlCenter::TemplateYamlTest < ActiveSupport::TestCase
  Y = ControlCenter::TemplateYaml

  test "parses a valid cmdscript template" do
    attrs, errors = Y.parse(<<~YAML)
      name: probe
      tags: [recon]
      desc: probe hosts
      output: probe.json
      commands:
        - command: httpx
          args: [-silent, -json]
          operator: "|"
        - command: nuclei
          args: [-severity, high]
      target:
        type: file
        separator: "\\n"
        output: targets.txt
    YAML
    assert_empty errors
    assert_equal "probe", attrs["name"]
    assert_equal "cmdscript", attrs["kind"]
    assert_equal ["recon"], attrs["tags"]
    assert_equal "probe hosts", attrs["description"]
    assert_equal "probe.json", attrs["output"]
    assert_equal 2, attrs["commands"].length
    assert_equal "httpx", attrs["commands"][0]["command"]
    assert_equal ["-silent", "-json"], attrs["commands"][0]["args"]
    assert_equal "|", attrs["commands"][0]["operator"]
    assert_equal "file", attrs["target"]["type"]
  end

  test "rejects a non-mapping root" do
    attrs, errors = Y.parse("- a\n- b")
    assert_nil attrs
    assert(errors.any? { |e| e.include?("must be a YAML mapping") })
  end

  test "rejects unknown top-level keys" do
    _attrs, errors = Y.parse("name: x\ncommands: []\nevil: 1")
    assert(errors.any? { |e| e.include?("unknown key") && e.include?("evil") })
  end

  test "rejects a Ruby object tag without instantiating it" do
    attrs, errors = Y.parse("--- !ruby/object:Kernel {}")
    assert_nil attrs
    refute_empty errors
  end

  test "rejects an alias/anchor bomb" do
    attrs, errors = Y.parse("a: &a [1,1]\nb: [*a, *a]\ncommands: *a\n")
    assert_nil attrs
    refute_empty errors
  end

  test "enforces the size cap" do
    attrs, errors = Y.parse("name: " + ("x" * 70_000))
    assert_nil attrs
    assert(errors.any? { |e| e.include?("too large") })
  end

  test "reports required and type errors" do
    attrs, errors = Y.parse("name: 5\ncommands: not-a-list")
    assert_nil attrs
    assert(errors.any? { |e| e.include?("name must be a string") })
    assert(errors.any? { |e| e.include?("commands must be a list") })
  end

  test "requires name" do
    attrs, errors = Y.parse("commands: []")
    assert_nil attrs
    assert(errors.any? { |e| e.include?("name is required") })
  end
end
