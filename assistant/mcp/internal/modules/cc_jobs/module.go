// Package cc_jobs provides the read-only list_jobs and get_job MCP tools
// over Control Center's Whiterabbit job history.
package cc_jobs

import (
	"regexp"

	"hunter.local/assistant/mcp/internal/readmodule"
	"hunter.local/assistant/mcp/internal/tool"
)

// idPattern matches the integer primary key of control_center_jobs.
var idPattern = regexp.MustCompile("^[1-9][0-9]{0,18}$")

type Module struct{}

func (Module) Tools() []tool.Tool {
	return readmodule.Build(readmodule.Spec{
		ListTool: "list_jobs", GetTool: "get_job", Scope: "control_center_jobs",
		BasePath: "/api/v1/assistant/machine/control_center/jobs", DetailKey: "job",
		ListDesc: "List and count Control Center Whiterabbit job runs, optionally filtered by status.",
		GetDesc:  "Return the full record for one Control Center job by id, excluding internal targeting fields.",
		ListFields: []readmodule.ListField{
			{Name: "status", Kind: "string", MaxLen: 40},
		},
		SummaryKeys: []string{"id", "template_name", "status", "queue_name", "target_count", "exit_status", "created_at"},
		FullKeys: []string{
			"id", "template_name", "status", "queue_name", "target_count", "exit_status", "created_at",
			"stdout", "stderr", "updated_at",
		},
		IDPattern: idPattern,
	})
}
