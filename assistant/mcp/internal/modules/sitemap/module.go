// Package sitemap provides the read-only list_endpoints and get_endpoint MCP
// tools over the crawled sitemap endpoint index (Postgres-backed).
package sitemap

import (
	"regexp"

	"hunter.local/assistant/mcp/internal/readmodule"
	"hunter.local/assistant/mcp/internal/tool"
)

// idPattern matches the bigint primary key of sitemap_endpoints.
var idPattern = regexp.MustCompile("^[1-9][0-9]{0,18}$")

type Module struct{}

func (Module) Tools() []tool.Tool {
	return readmodule.Build(readmodule.Spec{
		ListTool: "list_endpoints", GetTool: "get_endpoint", Scope: "sitemap",
		BasePath: "/api/v1/assistant/machine/sitemap/endpoints", DetailKey: "endpoint",
		ListDesc: "List and count crawled sitemap endpoints, optionally filtered by path, content type, HTTP methods, or status family.",
		GetDesc:  "Return the full record for one sitemap endpoint by id.",
		ListFields: []readmodule.ListField{
			{Name: "q", Kind: "string", MaxLen: 200},
			{Name: "path", Kind: "string", MaxLen: 500},
			{Name: "has_query", Kind: "string", MaxLen: 5},
			{Name: "content_type", Kind: "string", MaxLen: 100},
			{Name: "methods", Kind: "string", MaxLen: 200},
			{Name: "status", Kind: "string", MaxLen: 40},
		},
		SummaryKeys: []string{"id", "url", "path", "method", "status_code"},
		FullKeys: []string{
			"id", "url", "path", "method", "status_code",
			"origin", "content_type", "content_length", "first_seen_at", "last_seen_at",
			"program", "host", "scheme", "port",
		},
		IDPattern: idPattern,
	})
}
