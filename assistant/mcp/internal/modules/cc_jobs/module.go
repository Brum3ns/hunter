// Package cc_jobs provides the read-only list_jobs and get_job MCP tools
// over Control Center's Whiterabbit job history.
package cc_jobs

import (
	"encoding/json"
	"errors"
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
		GetDesc:  "Return the safe operational record for one Control Center job by its integer id, including targeting counts/source names and redacted output.",
		ListFields: []readmodule.ListField{
			{Name: "status", Kind: "string", MaxLen: 40, Description: "Filter by job status: queued, running, succeeded, failed, or pending."},
		},
		SummaryKeys: []string{"id", "template_name", "status", "queue_name", "target_count", "exit_status", "created_at"},
		FullKeys: []string{
			"id", "template_name", "status", "queue_name", "target_count", "exit_status", "created_at",
			"created_by", "target_chunk", "job_delay_ms", "selection_count", "manual_target_count", "selection_sources",
			"stdout", "stdout_redacted", "stderr", "stderr_redacted", "updated_at",
		},
		ValidateDetail: validateDetail,
		IDPattern:      idPattern,
	})
}

func validateDetail(detail map[string]json.RawMessage) error {
	if !readmodule.BoundedStringArray(detail["selection_sources"], 100, 16_384) {
		return errors.New("invalid job selection summary")
	}
	return nil
}
