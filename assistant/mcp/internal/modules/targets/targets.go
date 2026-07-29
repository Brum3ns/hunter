// Package targets provides the read-only list_targets and get_target MCP tools.
package targets

import (
	"hunter.local/assistant/mcp/internal/readmodule"
	"hunter.local/assistant/mcp/internal/tool"
)

type Module struct{}

func (Module) Tools() []tool.Tool {
	return readmodule.Build(readmodule.Spec{
		ListTool: "list_targets", GetTool: "get_target", Scope: "targets",
		BasePath: "/api/v1/assistant/machine/targets", DetailKey: "target",
		ListDesc: "List and count alive targets, optionally filtered by query, program, or status. Use q for dork search (see the q field for keys).",
		GetDesc:  "Return the full record for one alive target by its id.",
		ListFields: []readmodule.ListField{
			// Dork keys mirror Rails Targets::SearchParser::KEYS (source of truth).
			{Name: "q", Kind: "string", MaxLen: 200, Description: "Dork/free-text search. Keys: host,url,ip,port,method,scheme,path,title,webserver,content_type,tech,status,program,tool,page_type. Syntax: bare words = free text; key:value filters; multiple terms AND; quote values with spaces (no negation/wildcard operators). Example: status:200 tech:nginx."},
			{Name: "program", Kind: "string", MaxLen: 200, Description: "Filter by bug-bounty program name."},
			{Name: "status", Kind: "string", MaxLen: 40, Description: "Filter by HTTP status code, e.g. 200."},
		},
		SummaryKeys: []string{"id", "host", "program", "status_code", "title"},
		FullKeys: []string{
			"id", "host", "program", "status_code", "title",
			"url", "status_family", "webserver", "content_type",
			"port", "scheme", "tech", "seen_at", "page_type",
		},
	})
}
