// Package programs provides the read-only list_programs and get_program MCP
// tools.
package programs

import (
	"encoding/json"
	"errors"
	"regexp"

	"hunter.local/assistant/mcp/internal/analysismodule"
	"hunter.local/assistant/mcp/internal/readmodule"
	"hunter.local/assistant/mcp/internal/tool"
)

type Module struct{}

func (Module) Tools() []tool.Tool {
	tools := readmodule.Build(readmodule.Spec{
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
			{Name: "favorites_only", Kind: "string", MaxLen: 3, Description: "Set to yes to return only the current human user's favorites."},
			{Name: "trash_only", Kind: "string", MaxLen: 3, Description: "Set to yes to return only the current human user's trash."},
			{Name: "scope_count_gte", Kind: "string", MaxLen: 10, Description: "Minimum in-scope asset count."},
			{Name: "scope_count_lte", Kind: "string", MaxLen: 10, Description: "Maximum in-scope asset count."},
			{Name: "bounty_min_gte", Kind: "string", MaxLen: 20, Description: "Minimum published lower bounty bound."},
			{Name: "bounty_max_gte", Kind: "string", MaxLen: 20, Description: "Minimum published maximum bounty."},
			{Name: "reports_gte", Kind: "string", MaxLen: 10, Description: "Minimum resolved report count."},
			{Name: "reports_24h_gte", Kind: "string", MaxLen: 10, Description: "Minimum reports in the last 24 hours."},
			{Name: "reports_7d_gte", Kind: "string", MaxLen: 10, Description: "Minimum reports in the last 7 days."},
			{Name: "reports_month_gte", Kind: "string", MaxLen: 10, Description: "Minimum reports in the current month."},
			{Name: "response_lte", Kind: "string", MaxLen: 10, Description: "Maximum average first-response time in hours."},
			{Name: "platforms", Kind: "string", MaxLen: 200, Description: "Comma-separated platform slugs, e.g. hackerone,bugcrowd."},
			{Name: "scope_types", Kind: "string", MaxLen: 200, Description: "Comma-separated scope types, e.g. web,mobile."},
			{Name: "sort", Kind: "string", MaxLen: 40, Description: "Sort key (e.g. date, bounty_max, reports)."},
			{Name: "dir", Kind: "string", MaxLen: 10, Description: "Sort direction: asc or desc."},
		},
		SummaryKeys: []string{"sid", "name", "platform", "public", "bounty_range", "favorited", "trashed", "last_viewed_at"},
		FullKeys: []string{
			"sid", "name", "platform", "public", "bounty_range", "favorited", "trashed", "last_viewed_at",
			"slug", "url", "vdp", "bounty", "bounty_min", "bounty_max", "currency",
			"reward_avg", "reward_max", "report_count", "reports_24h", "reports_7d",
			"reports_month", "avg_response_hrs", "scope_count", "collaboration",
			"tags", "languages", "date", "status", "description", "description_redacted",
			"organization", "reward_grid", "hall_of_fame", "hacktivity", "rules", "rules_redacted",
			"qualifying_vulnerabilities", "non_qualifying_vulnerabilities", "account_access",
			"account_access_redacted", "required_user_agent", "restricted_ips", "vpn_active", "vpn_ips",
			"scope", "out_of_scope",
		},
		ValidateDetail: validateDetail,
	})
	tools = append(tools, analysismodule.Build(analysismodule.Spec{
		Name: "analyze_programs", Scope: "programs_read", Path: "/api/v1/assistant/machine/programs/analyze",
		Description: "Aggregate all matching programs server-side by platform, status, bounty mode, and tag.",
		Fields: []readmodule.ListField{
			{Name: "q", Kind: "string", MaxLen: 200}, {Name: "status", Kind: "string", MaxLen: 20},
			{Name: "bounty", Kind: "string", MaxLen: 20}, {Name: "collaboration", Kind: "string", MaxLen: 20},
			{Name: "platforms", Kind: "string", MaxLen: 200}, {Name: "scope_types", Kind: "string", MaxLen: 200},
		},
		GroupKeys: []string{"platform_counts", "status_counts", "bounty_counts", "tag_counts"},
	}))
	tools = append(tools, readmodule.BuildList(readmodule.Spec{
		ListTool: "list_program_changes", Scope: "programs_read",
		BasePath: "/api/v1/assistant/machine/programs/changes",
		ListDesc: "List the configured administrator's recent program changes.",
		ListFields: []readmodule.ListField{
			{Name: "platform", Kind: "string", MaxLen: 100}, {Name: "kind", Kind: "string", MaxLen: 100},
			{Name: "sid", Kind: "string", MaxLen: 255},
		},
		SummaryKeys: []string{"id", "platform", "program_sid", "program_name", "kind", "old_value", "new_value", "detected_at", "scope_run_id"},
	})...)
	runID := regexp.MustCompile("^[1-9][0-9]{0,18}$")
	tools = append(tools, readmodule.Build(readmodule.Spec{
		ListTool: "list_scope_runs", GetTool: "get_scope_run", Scope: "programs_read",
		BasePath: "/api/v1/assistant/machine/programs/scope_runs", DetailKey: "scope_run",
		ListDesc: "List bounded Scope collection runs.", GetDesc: "Get one Scope collection run.",
		ListFields: []readmodule.ListField{
			{Name: "mine", Kind: "string", MaxLen: 5}, {Name: "kind", Kind: "string", MaxLen: 50},
			{Name: "platform", Kind: "string", MaxLen: 100}, {Name: "status", Kind: "string", MaxLen: 10},
		},
		SummaryKeys: scopeRunKeys, FullKeys: scopeRunKeys, IDPattern: runID,
	})...)
	return tools
}

var scopeRunKeys = []string{
	"id", "kind", "platform", "trigger", "mode", "bug_bounty", "vdp", "programs", "success",
	"in_flight", "exit_status", "duration_ms", "stdout_bytes", "stdout_excerpt", "stderr_excerpt",
	"error_class", "started_at", "finished_at", "user",
}

func validateDetail(detail map[string]json.RawMessage) error {
	organizationKeys := []string{"name", "slug", "description", "currency"}
	rewardKeys := []string{"low", "medium", "high", "critical"}
	scopeKeys := []string{"asset", "type", "type_name", "value", "bounty", "inscope", "report_count"}
	validOrganization := func(value map[string]json.RawMessage) bool {
		return readmodule.StringValue(value["name"], 16_384, true) &&
			readmodule.StringValue(value["slug"], 16_384, true) &&
			readmodule.StringValue(value["description"], 16_384, true) &&
			readmodule.StringValue(value["currency"], 16_384, true)
	}
	validRewards := func(value map[string]json.RawMessage) bool {
		return readmodule.NumberValue(value["low"], true) && readmodule.NumberValue(value["medium"], true) &&
			readmodule.NumberValue(value["high"], true) && readmodule.NumberValue(value["critical"], true)
	}
	validScope := func(value map[string]json.RawMessage) bool {
		return readmodule.StringValue(value["asset"], 16_384, true) &&
			readmodule.StringValue(value["type"], 16_384, true) &&
			readmodule.StringValue(value["type_name"], 16_384, true) &&
			readmodule.StringValue(value["value"], 16_384, true) &&
			readmodule.BooleanValue(value["bounty"], true) &&
			readmodule.BooleanValue(value["inscope"], true) &&
			readmodule.IntegerValue(value["report_count"], 0, 9_223_372_036_854_775_807, true)
	}
	if !readmodule.TypedObject(detail["organization"], organizationKeys, validOrganization) ||
		!readmodule.TypedObject(detail["reward_grid"], rewardKeys, validRewards) ||
		!readmodule.TypedObjectArray(detail["scope"], scopeKeys, 500, validScope) ||
		!readmodule.TypedObjectArray(detail["out_of_scope"], scopeKeys, 500, validScope) ||
		!readmodule.BoundedStringArray(detail["tags"], 500, 16_384) ||
		!readmodule.BoundedStringArray(detail["languages"], 500, 16_384) ||
		!readmodule.BoundedStringArray(detail["qualifying_vulnerabilities"], 500, 16_384) ||
		!readmodule.BoundedStringArray(detail["non_qualifying_vulnerabilities"], 500, 16_384) ||
		!readmodule.BoundedStringArray(detail["restricted_ips"], 500, 16_384) ||
		!readmodule.BoundedStringArray(detail["vpn_ips"], 500, 16_384) {
		return errors.New("invalid nested program projection")
	}
	return nil
}
