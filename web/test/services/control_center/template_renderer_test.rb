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

  test "omits output and target when blank" do
    t = ControlCenter::Template.new(name: "x", commands: [{ "command" => "httpx", "args" => [], "operator" => "" }])
    parsed = YAML.safe_load(ControlCenter::TemplateRenderer.to_yaml(t))
    assert_not parsed.key?("output")
    assert_not parsed.key?("target")
  end
end
