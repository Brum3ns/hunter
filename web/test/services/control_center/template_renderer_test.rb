require "test_helper"
require "yaml"

class ControlCenter::TemplateRendererTest < ActiveSupport::TestCase
  test "renders a template to cmdscript YAML that round-trips" do
    t = ControlCenter::Template.new(
      name: "probe", tags: ["recon"], description: "probe hosts", output: "probe.json",
      commands: [{ "command" => "httpx", "args" => ["-silent"], "operator" => "|" },
                 { "command" => "nuclei", "args" => ["-severity", "high"], "operator" => "" }]
    )
    parsed = YAML.safe_load(ControlCenter::TemplateRenderer.to_yaml(t))

    assert_equal "probe", parsed["name"]
    assert_equal ["recon"], parsed["tags"]
    assert_equal "probe hosts", parsed["desc"]
    assert_equal "probe.json", parsed["output"]
    assert_equal 2, parsed["commands"].length
    assert_equal "httpx", parsed["commands"][0]["command"]
    assert_equal ["-silent"], parsed["commands"][0]["args"]
    assert_equal "|", parsed["commands"][0]["operator"]
    assert_nil parsed["commands"][1]["operator"] # blank operator omitted
  end

  test "groups each flag with its values into a flow-style sub-array" do
    t = ControlCenter::Template.new(
      name: "probe",
      commands: [{ "command" => "httpx",
                   "args" => ["-u", "https://ginandjuice.shop/", "-t", "10", "-rl", "10", "-H", "X-One: 1", "X-Twi: 2"],
                   "operator" => "" }]
    )
    yaml = ControlCenter::TemplateRenderer.to_yaml(t)
    args = YAML.safe_load(yaml)["commands"][0]["args"]

    assert_equal(
      [["-u", "https://ginandjuice.shop/"], ["-t", "10"], ["-rl", "10"], ["-H", "X-One: 1", "X-Twi: 2"]],
      args
    )
    # Every leaf stays a String (Whiterabbit asserts each group element is a
    # string) and flattens back to the original argv in order.
    assert(args.flatten.all? { |x| x.is_a?(String) })
    assert_equal(
      ["-u", "https://ginandjuice.shop/", "-t", "10", "-rl", "10", "-H", "X-One: 1", "X-Twi: 2"],
      args.flatten
    )
    # Groups render compactly, not as block sub-sequences, with every scalar quoted.
    assert_includes yaml, "['-H', 'X-One: 1', 'X-Twi: 2']"
  end

  test "quotes every scalar in a group so plain and boolean-looking values stay strings" do
    t = ControlCenter::Template.new(
      name: "probe", commands: [{ "command" => "tool", "args" => ["-a", "x", "-b", "y"], "operator" => "" }]
    )
    yaml = ControlCenter::TemplateRenderer.to_yaml(t)

    # Both values quoted the same way — no "-a", x (plain) vs "-b", "y" (quoted) split.
    assert_includes yaml, "['-a', 'x']"
    assert_includes yaml, "['-b', 'y']"
    assert_equal [["-a", "x"], ["-b", "y"]], YAML.safe_load(yaml)["commands"][0]["args"]
  end

  test "quotes a bare (non-flag) leading arg token" do
    t = ControlCenter::Template.new(
      name: "probe", commands: [{ "command" => "run", "args" => ["scan", "-u", "x.com"], "operator" => "" }]
    )
    yaml = ControlCenter::TemplateRenderer.to_yaml(t)

    assert_includes yaml, "- 'scan'"
    assert_includes yaml, "['-u', 'x.com']"
    assert_equal ["scan", ["-u", "x.com"]], YAML.safe_load(yaml)["commands"][0]["args"]
  end

  test "leaves value-less flags as a flat args list" do
    t = ControlCenter::Template.new(
      name: "probe", commands: [{ "command" => "httpx", "args" => ["-silent", "-json"], "operator" => "" }]
    )
    args = YAML.safe_load(ControlCenter::TemplateRenderer.to_yaml(t))["commands"][0]["args"]
    assert_equal ["-silent", "-json"], args
  end

  test "omits output and target when blank" do
    t = ControlCenter::Template.new(name: "x", commands: [{ "command" => "httpx", "args" => [], "operator" => "" }])
    parsed = YAML.safe_load(ControlCenter::TemplateRenderer.to_yaml(t))
    assert_not parsed.key?("output")
    assert_not parsed.key?("target")
  end
end
