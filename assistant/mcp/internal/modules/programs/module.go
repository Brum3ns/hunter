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
		ListDesc: "List and count bug-bounty programs, optionally filtered by status, bounty, collaboration, scope size, report volume, platform, or scope type.",
		GetDesc:  "Return the full record for one program by sid.",
		ListFields: []readmodule.ListField{
			{Name: "q", Kind: "string", MaxLen: 200},
			{Name: "status", Kind: "string", MaxLen: 20},
			{Name: "bounty", Kind: "string", MaxLen: 20},
			{Name: "collaboration", Kind: "string", MaxLen: 20},
			{Name: "scope_count_gte", Kind: "string", MaxLen: 10},
			{Name: "scope_count_lte", Kind: "string", MaxLen: 10},
			{Name: "reports_gte", Kind: "string", MaxLen: 10},
			{Name: "platforms", Kind: "string", MaxLen: 200},
			{Name: "scope_types", Kind: "string", MaxLen: 200},
			{Name: "sort", Kind: "string", MaxLen: 40},
			{Name: "dir", Kind: "string", MaxLen: 10},
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
