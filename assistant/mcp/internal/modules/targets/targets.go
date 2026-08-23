// Package targets provides the read-only list_targets and get_target MCP tools.
package targets

import (
	"encoding/json"
	"errors"

	"hunter.local/assistant/mcp/internal/analysismodule"
	"hunter.local/assistant/mcp/internal/readmodule"
	"hunter.local/assistant/mcp/internal/tool"
)

type Module struct{}

func (Module) Tools() []tool.Tool {
	fields := []readmodule.ListField{
		{Name: "q", Kind: "string", MaxLen: 200, Description: "Dork/free-text target search."},
		{Name: "program", Kind: "string", MaxLen: 200, Description: "Program name."},
		{Name: "status", Kind: "string", MaxLen: 40, Description: "HTTP status."},
	}
	tools := readmodule.Build(readmodule.Spec{
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
			"port", "scheme", "tech", "seen_at", "page_type", "input", "ip", "path", "method",
			"content_length", "words", "lines", "response_time", "tool", "failed", "phash",
			"csp_fqdns", "csp_domains", "response_headers",
		},
		ValidateDetail: validateDetail,
	})
	return append(tools, analysismodule.Build(analysismodule.Spec{
		Name: "analyze_targets", Scope: "targets_read", Path: "/api/v1/assistant/machine/targets/analyze",
		Description: "Aggregate all matching targets server-side by technology, status, program, and webserver.",
		Fields:      fields,
		GroupKeys:   []string{"technology_counts", "status_counts", "program_counts", "webserver_counts"},
	}))
}

func validateDetail(detail map[string]json.RawMessage) error {
	headerKeys := []string{"name", "value", "redacted"}
	if !readmodule.BoundedStringArray(detail["tech"], 500, 4_096) ||
		!readmodule.BoundedStringArray(detail["csp_fqdns"], 500, 4_096) ||
		!readmodule.BoundedStringArray(detail["csp_domains"], 500, 4_096) ||
		!readmodule.TypedObjectArray(detail["response_headers"], headerKeys, 50,
			func(header map[string]json.RawMessage) bool {
				return readmodule.StringValue(header["name"], 200, false) &&
					readmodule.StringValue(header["value"], 4_096, true) &&
					readmodule.BooleanValue(header["redacted"], false)
			}) {
		return errors.New("invalid nested target projection")
	}
	return nil
}
