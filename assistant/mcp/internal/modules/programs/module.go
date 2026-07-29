// Package programs provides the read-only list_programs and get_program MCP
// tools.
package programs

import (
	"hunter.local/assistant/mcp/internal/readmodule"
	"hunter.local/assistant/mcp/internal/tool"
)

type Module struct{}

func (Module) Tools() []tool.Tool {
	return readmodule.Build(readmodule.Spec{
		ListTool: "list_programs", GetTool: "get_program", Scope: "programs",
		BasePath: "/api/v1/assistant/machine/programs", DetailKey: "program",
		ListDesc: "List and count bug-bounty programs, optionally filtered by status, bounty, collaboration, scope size, report volume, platform, or scope type. Use q for dork search (see the q field for keys).",
		GetDesc:  "Return the full record for one program by its sid.",
		ListFields: []readmodule.ListField{
			// Dork keys mirror Rails Programs::SearchParser::KEYS (source of truth).
			{Name: "q", Kind: "string", MaxLen: 200, Description: "Dork/free-text search. Keys: asset,program,name,slug,org,organization,tag,lang,language,platform,mode,bounty,vdp,active,hof,hall_of_fame,reports,reports_24h,reports_7d,reports_30d,reports_month,scope,avg,avg_reward,max,max_reward,min,min_reward,response. Syntax: bare words = free text; key:value filters; multiple terms AND; quote values with spaces (no negation/wildcard operators). Example: platform:hackerone bounty:yes."},
			{Name: "status", Kind: "string", MaxLen: 20, Description: "Filter by program status: public or private."},
			{Name: "bounty", Kind: "string", MaxLen: 20, Description: "Filter by bounty presence: with or without."},
			{Name: "collaboration", Kind: "string", MaxLen: 20, Description: "Filter by collaboration: yes or no."},
			{Name: "scope_count_gte", Kind: "string", MaxLen: 10, Description: "Minimum in-scope asset count."},
			{Name: "scope_count_lte", Kind: "string", MaxLen: 10, Description: "Maximum in-scope asset count."},
			{Name: "reports_gte", Kind: "string", MaxLen: 10, Description: "Minimum resolved report count."},
			{Name: "platforms", Kind: "string", MaxLen: 200, Description: "Comma-separated platform slugs, e.g. hackerone,bugcrowd."},
			{Name: "scope_types", Kind: "string", MaxLen: 200, Description: "Comma-separated scope types, e.g. web,mobile."},
			{Name: "sort", Kind: "string", MaxLen: 40, Description: "Sort key (e.g. date, bounty_max, reports)."},
			{Name: "dir", Kind: "string", MaxLen: 10, Description: "Sort direction: asc or desc."},
		},
		SummaryKeys: []string{"sid", "name", "platform", "public", "bounty_range"},
		FullKeys: []string{
			"sid", "name", "platform", "public", "bounty_range",
			"slug", "url", "vdp", "bounty", "bounty_min", "bounty_max", "currency",
			"reward_avg", "reward_max", "report_count", "reports_24h", "reports_7d",
			"reports_month", "avg_response_hrs", "scope_count", "collaboration",
			"tags", "languages", "scope", "out_of_scope",
		},
	})
}
