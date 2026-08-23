require "test_helper"

class Assistant::CatalogParityTest < ActiveSupport::TestCase
  ROOT = Rails.root.parent.freeze

  test "Rails MCP Codex and Claude expose the same exact reviewed catalog" do
    expected = Assistant::CapabilityCatalog.load.tools.map do |entry|
      [ entry.fetch("name"), entry.fetch("scope") ]
    end
    go_source = File.read(ROOT.join("assistant/mcp/internal/catalog/catalog.go"))
    go_catalog = go_source.lines.filter_map do |line|
      match = line.match(/\{Name: "([a-z][a-z0-9_]*)".*?Scope: "([a-z][a-z0-9_]*)"/)
      [ match[1], match[2] ] if match
    end

    assert_equal expected, go_catalog
    assert_equal expected.map(&:first), provider_names(
      ROOT.join("assistant/codex/cmd/hunter-assistant-codex/main.go")
    )
    assert_equal expected.map(&:first), provider_names(
      ROOT.join("assistant/claude/cmd/hunter-assistant-claude/main.go"),
      prefix: "mcp__hunter__"
    )
  end

  private

  def provider_names(path, prefix: "")
    source = File.read(path)
    match = source.match(/var defaultMCPTools = strings\.Fields\((.*?)\n\)/m)
    assert match, "#{path} has no defaultMCPTools declaration"

    match[1].scan(/"([^"]*)"/).flatten.join.split.map do |name|
      assert name.start_with?(prefix), "#{name.inspect} lacks #{prefix.inspect}" if prefix.present?
      name.delete_prefix(prefix)
    end
  end
end
