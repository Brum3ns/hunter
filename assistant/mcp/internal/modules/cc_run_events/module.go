// Package cc_run_events provides the read-only list_run_events MCP tool
// over Control Center's Ansible run event stream. There is no get_run_event
// — events are always listed under a run.
package cc_run_events

import (
	"hunter.local/assistant/mcp/internal/readmodule"
	"hunter.local/assistant/mcp/internal/tool"
)

type Module struct{}

func (Module) Tools() []tool.Tool {
	return readmodule.BuildList(readmodule.Spec{
		ListTool: "list_run_events", Scope: "control_center_ansible",
		BasePath: "/api/v1/assistant/machine/control_center/ansible/run_events",
		ListDesc: "List and count Control Center Ansible run events for a run, cursor-paginated by after_counter.",
		ListFields: []readmodule.ListField{
			{Name: "run_id", Kind: "int", Min: 1, Max: 999999999999999999},
			{Name: "after_counter", Kind: "int", Min: 0, Max: 999999999999999999},
		},
		SummaryKeys: []string{
			"id", "counter", "event_uuid", "parent_uuid", "event_type", "play", "task", "host",
			"event_time", "stdout", "event_data", "truncated", "created_at",
		},
		MaxItems: 100,
	})
}
