// Package cc_runs provides the read-only get_run MCP tool over Control
// Center's Ansible run history. There is no list_runs — runs are listed via
// a parent get_run_group.
package cc_runs

import (
	"regexp"

	"hunter.local/assistant/mcp/internal/readmodule"
	"hunter.local/assistant/mcp/internal/tool"
)

// idPattern matches the integer primary key of control_center_ansible_runs.
var idPattern = regexp.MustCompile("^[1-9][0-9]{0,18}$")

type Module struct{}

func (Module) Tools() []tool.Tool {
	return readmodule.BuildGet(readmodule.Spec{
		GetTool: "get_run", Scope: "control_center_ansible",
		BasePath: "/api/v1/assistant/machine/control_center/ansible/runs", DetailKey: "run",
		GetDesc: "Return the full record for one Control Center Ansible run by id, excluding secret snapshot fields (playbook_yaml, inventory_yaml, known_hosts, lease_digest, runner_id).",
		FullKeys: []string{
			"id", "run_group_id", "playbook_id", "position", "status", "playbook_name", "inventory_name",
			"credential_name", "credential_fingerprint", "variable_audit", "secret_variable_names",
			"host_limit", "check_mode", "timeout_seconds", "error_code", "error_detail", "exit_status",
			"ok_count", "changed_count", "failed_count", "unreachable_count", "stored_event_bytes",
			"truncated", "queued_at", "started_at", "completed_at", "cancel_requested_at", "created_at", "updated_at",
		},
		IDPattern: idPattern,
	})
}
