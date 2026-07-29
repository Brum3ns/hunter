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
		GetDesc:  "Return the full record for one CVE by id (e.g. CVE-2024-1234; GHSA ids also accepted).",
		ListFields: []readmodule.ListField{
			// cves has no Rails SearchParser; q is a plain substring search.
			{Name: "q", Kind: "string", MaxLen: 200, Description: "Plain case-insensitive substring search over CVE id, summary, and details. Not a dork — use the typed filters for precise matches."},
			{Name: "ecosystem", Kind: "string", MaxLen: 100, Description: "Package ecosystem, e.g. npm, PyPI, Go."},
			{Name: "package", Kind: "string", MaxLen: 200, Description: "Affected package name."},
			{Name: "language", Kind: "string", MaxLen: 100, Description: "Affected language."},
			{Name: "vendor", Kind: "string", MaxLen: 100, Description: "Affected vendor."},
			{Name: "cwe", Kind: "string", MaxLen: 40, Description: "CWE id, e.g. CWE-79."},
			{Name: "tag", Kind: "string", MaxLen: 100, Description: "Filter by tag."},
			{Name: "has_fix", Kind: "string", MaxLen: 5, Description: "Whether a fix is available: pass true or false."},
			{Name: "min_severity", Kind: "string", MaxLen: 10, Description: "Minimum severity: critical, high, medium, or low."},
			{Name: "published_after", Kind: "string", MaxLen: 40, Description: "ISO-8601 datetime, e.g. 2024-01-01T00:00:00Z (a bare date is rejected); only CVEs published on/after it."},
			{Name: "modified_after", Kind: "string", MaxLen: 40, Description: "ISO-8601 datetime, e.g. 2024-01-01T00:00:00Z (a bare date is rejected); only CVEs modified on/after it."},
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
