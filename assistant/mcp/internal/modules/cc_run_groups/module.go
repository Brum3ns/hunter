// Package cc_run_groups provides the read-only list_run_groups and
// get_run_group MCP tools over Control Center's Ansible run groups.
package cc_run_groups

import (
	"regexp"

	"hunter.local/assistant/mcp/internal/readmodule"
	"hunter.local/assistant/mcp/internal/tool"
)

// idPattern matches the integer primary key of control_center_ansible_run_groups.
var idPattern = regexp.MustCompile("^[1-9][0-9]{0,18}$")

type Module struct{}

func (Module) Tools() []tool.Tool {
	return readmodule.Build(readmodule.Spec{
		ListTool: "list_run_groups", GetTool: "get_run_group", Scope: "control_center_ansible",
		BasePath: "/api/v1/assistant/machine/control_center/ansible/run_groups", DetailKey: "run_group",
		ListDesc: "List and count Control Center Ansible run groups, newest first. Page with page/limit.",
		GetDesc:  "Return the full record for one run group by its integer id, including child run summaries. Never includes execution_payload.",
		SummaryKeys: []string{
			"id", "status", "execution_mode", "failure_policy", "inventory_id", "credential_id",
			"started_at", "completed_at", "created_at",
		},
		FullKeys: []string{
			"id", "status", "execution_mode", "failure_policy", "inventory_id", "credential_id",
			"started_at", "completed_at", "created_at",
			"concurrency_limit", "launch_snapshot", "cancel_requested_at", "updated_at", "runs",
		},
		IDPattern: idPattern,
	})
}
