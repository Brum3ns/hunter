#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

ruby - "$repo_root" <<'RUBY'
require "yaml"

root = ARGV.fetch(0)
catalog_path = File.join(root, "web/config/assistant_capabilities.yml")
go_catalog_path = File.join(root, "assistant/mcp/internal/catalog/catalog.go")
codex_path = File.join(root, "assistant/codex/cmd/hunter-assistant-codex/main.go")
claude_path = File.join(root, "assistant/claude/cmd/hunter-assistant-claude/main.go")

catalog = YAML.safe_load_file(catalog_path, aliases: false)
expected = catalog.fetch("tools").map { |entry| entry.fetch("name") }

go_names = File.read(go_catalog_path).scan(/\{Name: "([a-z][a-z0-9_]*)"/).flatten

def provider_names(path, prefix: "")
  source = File.read(path)
  match = source.match(/var defaultMCPTools = strings\.Fields\((.*?)\n\)/m)
  abort "#{path}: defaultMCPTools declaration not found" unless match
  block = match[1]
  raw = block.scan(/"([^"]*)"/).flatten.join
  raw.split.map do |name|
    unless prefix.empty?
      abort "#{path}: unexpected tool name #{name.inspect}" unless name.start_with?(prefix)
      name = name.delete_prefix(prefix)
    end
    name
  end
end

sources = {
  "Go MCP catalog" => go_names,
  "Codex default allowlist" => provider_names(codex_path),
  "Claude default allowlist" => provider_names(claude_path, prefix: "mcp__hunter__")
}

failures = sources.filter_map do |label, actual|
  next if actual == expected && actual.uniq.length == actual.length

  missing = expected - actual
  extra = actual - expected
  "#{label} differs (count=#{actual.length}, missing=#{missing.inspect}, extra=#{extra.inspect}, order_match=#{actual == expected})"
end

abort failures.join("\n") if failures.any?
puts "Hunter MCP catalog parity verified: #{expected.length} exact tools across Rails, MCP, Codex, and Claude"
RUBY
