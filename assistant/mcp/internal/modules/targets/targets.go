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
		ListDesc: "List and count alive targets, optionally filtered by query, program, or status.",
		GetDesc:  "Return the full record for one target by id.",
		ListFields: []readmodule.ListField{
			{Name: "q", Kind: "string", MaxLen: 200},
			{Name: "program", Kind: "string", MaxLen: 200},
			{Name: "status", Kind: "string", MaxLen: 40},
		},
		SummaryKeys: []string{"id", "host", "program", "status_code", "title"},
		FullKeys: []string{
			"id", "host", "program", "status_code", "title",
			"url", "status_family", "webserver", "content_type",
			"port", "scheme", "tech", "seen_at", "page_type",
		},
	})
}
