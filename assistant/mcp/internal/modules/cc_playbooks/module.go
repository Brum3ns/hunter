// Package cc_playbooks provides the read-only list_playbooks and
// get_playbook MCP tools over Control Center's Ansible playbooks.
package cc_playbooks

import (
	"encoding/json"
	"errors"
	"regexp"

	"hunter.local/assistant/mcp/internal/readmodule"
	"hunter.local/assistant/mcp/internal/tool"
)

// idPattern matches the integer primary key of control_center_ansible_playbooks.
var idPattern = regexp.MustCompile("^[1-9][0-9]{0,18}$")

type Module struct{}

func (Module) Tools() []tool.Tool {
	return readmodule.Build(readmodule.Spec{
		ListTool: "list_playbooks", GetTool: "get_playbook", Scope: "control_center_ansible",
		BasePath: "/api/v1/assistant/machine/control_center/ansible/playbooks", DetailKey: "playbook",
		ListDesc:    "List and count Control Center Ansible playbooks, ordered by name. Page with page/limit.",
		GetDesc:     "Return the full record for one Ansible playbook by its integer id.",
		SummaryKeys: []string{"id", "name", "description", "checksum", "lock_version", "created_by", "updated_at"},
		FullKeys: []string{
			"id", "name", "description", "checksum", "lock_version", "created_by", "updated_at",
			"yaml_content", "variable_set_ids", "created_at",
		},
		ValidateDetail: validateDetail,
		IDPattern:      idPattern,
	})
}

func validateDetail(detail map[string]json.RawMessage) error {
	if !readmodule.BoundedIntegerArray(detail["variable_set_ids"], 100, 1, 9_223_372_036_854_775_807, true) {
		return errors.New("invalid playbook variable set projection")
	}
	return nil
}
