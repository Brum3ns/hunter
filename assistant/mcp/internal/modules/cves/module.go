// Package cves provides the read-only list_cves and get_cve MCP tools.
package cves

import (
	"hunter.local/assistant/mcp/internal/readmodule"
	"hunter.local/assistant/mcp/internal/tool"
)

type Module struct{}

func (Module) Tools() []tool.Tool {
	return readmodule.Build(readmodule.Spec{
		ListTool: "list_cves", GetTool: "get_cve", Scope: "cves",
		BasePath: "/api/v1/assistant/machine/cves", DetailKey: "cve",
		ListDesc: "List and count tracked CVEs, optionally filtered by ecosystem, package, severity, or fix status.",
		GetDesc:  "Return the full record for one CVE by id.",
		ListFields: []readmodule.ListField{
			{Name: "q", Kind: "string", MaxLen: 200},
			{Name: "ecosystem", Kind: "string", MaxLen: 100},
			{Name: "package", Kind: "string", MaxLen: 200},
			{Name: "language", Kind: "string", MaxLen: 100},
			{Name: "vendor", Kind: "string", MaxLen: 100},
			{Name: "cwe", Kind: "string", MaxLen: 40},
			{Name: "tag", Kind: "string", MaxLen: 100},
			{Name: "has_fix", Kind: "string", MaxLen: 5},
			{Name: "min_severity", Kind: "string", MaxLen: 10},
			{Name: "published_after", Kind: "string", MaxLen: 40},
			{Name: "modified_after", Kind: "string", MaxLen: 40},
		},
		SummaryKeys: []string{"id", "summary", "severity_level", "severity_score", "has_fix", "modified"},
		FullKeys: []string{
			"id", "summary", "severity_level", "severity_score", "has_fix", "modified",
			"details", "aliases", "published", "withdrawn", "cwe_ids", "ecosystems",
			"languages", "vendors", "tags", "affected", "references", "chain",
			"osv_id", "first_seen_at", "last_synced_at",
		},
	})
}
