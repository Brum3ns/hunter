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
		ListDesc: "List and count tracked vulnerabilities, optionally filtered by program, severity, status, or tool. Use q for dork search (see the q field for keys).",
		GetDesc:  "Return the full record for one vulnerability by its Mongo ObjectId hex id.",
		ListFields: []readmodule.ListField{
			// Dork keys mirror Rails Vulnerabilities::SearchParser::KEYS (source of truth).
			{Name: "q", Kind: "string", MaxLen: 200, Description: "Dork/free-text search. Keys: severity,status,tool,type,program,asset,name,cwe,tag,host,url,ip,port,method,submitted,confidence,date. Syntax: bare words = free text; key:value filters; multiple terms AND; quote values with spaces (no negation/wildcard operators). Example: severity:high status:open."},
			{Name: "program", Kind: "string", MaxLen: 200, Description: "Filter by program name."},
			{Name: "severity", Kind: "string", MaxLen: 40, Description: "Filter by finding severity (e.g. critical, high, medium, low)."},
			{Name: "status", Kind: "string", MaxLen: 40, Description: "Filter by report status (e.g. open, triaged, resolved)."},
			{Name: "tool", Kind: "string", MaxLen: 100, Description: "Filter by the tool that produced the finding."},
		},
		SummaryKeys: []string{"id", "name", "severity", "status", "program"},
		FullKeys: []string{
			"id", "name", "severity", "status", "program",
			"type", "cwe", "tags", "tool", "asset", "date", "description", "impact",
			"host", "url", "ip", "port", "submitted", "status_updated_at", "confidence",
		},
	})
}
