// Package sitemap provides the read-only list_endpoints and get_endpoint MCP
// tools over the crawled sitemap endpoint index (Postgres-backed).
package sitemap

import (
	"regexp"

	"hunter.local/assistant/mcp/internal/analysismodule"
	"hunter.local/assistant/mcp/internal/readmodule"
	"hunter.local/assistant/mcp/internal/tool"
)

// idPattern matches the bigint primary key of sitemap_endpoints.
var idPattern = regexp.MustCompile("^[1-9][0-9]{0,18}$")

type Module struct{}

func (Module) Tools() []tool.Tool {
	fields := []readmodule.ListField{
		{Name: "q", Kind: "string", MaxLen: 200}, {Name: "path", Kind: "string", MaxLen: 500},
		{Name: "has_query", Kind: "string", MaxLen: 5}, {Name: "content_type", Kind: "string", MaxLen: 100},
		{Name: "methods", Kind: "string", MaxLen: 200}, {Name: "status", Kind: "string", MaxLen: 40},
	}
	tools := readmodule.Build(readmodule.Spec{
		ListTool: "list_endpoints", GetTool: "get_endpoint", Scope: "sitemap",
		BasePath: "/api/v1/assistant/machine/sitemap/endpoints", DetailKey: "endpoint",
		ListDesc: "List and count crawled sitemap endpoints, optionally filtered by path, content type, HTTP methods, or status family. Use q for dork search (see the q field for keys).",
		GetDesc:  "Return the full record for one sitemap endpoint by its integer id.",
		ListFields: []readmodule.ListField{
			// Dork keys mirror Rails Sitemap::SearchParser::KEYS (source of truth).
			{Name: "q", Kind: "string", MaxLen: 200, Description: "Dork/free-text search. Keys: host,origin,program,path,url,content_type,method,scheme,port,status,length,has_query,root,seen. Syntax: bare words = free text; key:value filters; multiple terms AND; quote values with spaces (no negation/wildcard operators). Example: path:/admin status:200."},
			{Name: "path", Kind: "string", MaxLen: 500, Description: "Filter by URL path (substring)."},
			{Name: "has_query", Kind: "string", MaxLen: 5, Description: "Filter to endpoints whose URL has a query string (true/false)."},
			{Name: "content_type", Kind: "string", MaxLen: 100, Description: "Filter by response content type (substring)."},
			{Name: "methods", Kind: "string", MaxLen: 200, Description: "Comma-separated HTTP methods to include, e.g. GET,POST."},
			{Name: "status", Kind: "string", MaxLen: 40, Description: "Filter by HTTP status family: 2,3,4,5."},
		},
		SummaryKeys: []string{"id", "url", "path", "method", "status_code"},
		FullKeys: []string{
			"id", "url", "path", "method", "status_code",
			"origin", "content_type", "content_length", "first_seen_at", "last_seen_at",
			"program", "host", "scheme", "port",
		},
		IDPattern: idPattern,
	})
	return append(tools, analysismodule.Build(analysismodule.Spec{
		Name: "analyze_endpoints", Scope: "sitemap_read", Path: "/api/v1/assistant/machine/sitemap/endpoints/analyze",
		Description: "Aggregate all matching sitemap endpoints server-side by method, status, content type, and origin.",
		Fields:      fields, GroupKeys: []string{"method_counts", "status_counts", "content_type_counts", "origin_counts"},
	}))
}
