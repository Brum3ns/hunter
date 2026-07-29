// Package vulnerabilities provides the read-only list_vulnerabilities and
// get_vulnerability MCP tools.
package vulnerabilities

import (
	"hunter.local/assistant/mcp/internal/readmodule"
	"hunter.local/assistant/mcp/internal/tool"
)

type Module struct{}

func (Module) Tools() []tool.Tool {
	return readmodule.Build(readmodule.Spec{
		ListTool: "list_vulnerabilities", GetTool: "get_vulnerability", Scope: "vulnerabilities",
		BasePath: "/api/v1/assistant/machine/vulnerabilities", DetailKey: "vulnerability",
		ListDesc: "List and count tracked vulnerabilities, optionally filtered by program, severity, status, or tool.",
		GetDesc:  "Return the full record for one vulnerability by id.",
		ListFields: []readmodule.ListField{
			{Name: "q", Kind: "string", MaxLen: 200},
			{Name: "program", Kind: "string", MaxLen: 200},
			{Name: "severity", Kind: "string", MaxLen: 40},
			{Name: "status", Kind: "string", MaxLen: 40},
			{Name: "tool", Kind: "string", MaxLen: 100},
		},
		SummaryKeys: []string{"id", "name", "severity", "status", "program"},
		FullKeys: []string{
			"id", "name", "severity", "status", "program",
			"type", "cwe", "tags", "tool", "asset", "date", "description", "impact",
			"host", "url", "ip", "port", "submitted", "status_updated_at", "confidence",
		},
	})
}
