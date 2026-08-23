// Package operational exposes Hunter's reviewed operational API actions that
// are not part of the existing discovery read modules. Every tool is named,
// routed, decoded, and validated independently; there is no generic request
// or arbitrary API proxy.
package operational

import (
	"encoding/json"
	"errors"
	"regexp"

	"hunter.local/assistant/mcp/internal/analysismodule"
	"hunter.local/assistant/mcp/internal/codec"
	"hunter.local/assistant/mcp/internal/readmodule"
	"hunter.local/assistant/mcp/internal/tool"
)

type Module struct{}

var integerID = regexp.MustCompile(`^[1-9][0-9]{0,18}$`)

func (Module) Tools() []tool.Tool {
	tools := []tool.Tool{
		analysismodule.Build(analysismodule.Spec{
			Name: "analyze_templates", Scope: "control_center_templates_read",
			Path:        "/api/v1/assistant/machine/control_center/templates/analyze",
			Description: "Analyze all matching Whiterabbit templates server-side and return bounded aggregate counts.",
			Fields:      []readmodule.ListField{{Name: "kind", Kind: "string", MaxLen: 40}},
			GroupKeys:   []string{"kind_counts", "tag_counts", "creator_counts"},
		}),
		analysismodule.Build(analysismodule.Spec{
			Name: "analyze_jobs", Scope: "control_center_jobs_read",
			Path:        "/api/v1/assistant/machine/control_center/jobs/analyze",
			Description: "Analyze all matching Whiterabbit jobs server-side and return bounded aggregate counts.",
			Fields:      []readmodule.ListField{{Name: "status", Kind: "string", MaxLen: 40}},
			GroupKeys:   []string{"status_counts", "template_counts", "queue_counts"},
		}),
		analysismodule.Build(analysismodule.Spec{
			Name: "analyze_playbooks", Scope: "control_center_ansible_read",
			Path:        "/api/v1/assistant/machine/control_center/ansible/playbooks/analyze",
			Description: "Analyze all Ansible playbooks server-side and return bounded aggregate counts.",
			GroupKeys:   []string{"creator_counts", "variable_set_counts", "module_counts"},
		}),
		analysismodule.Build(analysismodule.Spec{
			Name: "analyze_ansible_runs", Scope: "control_center_ansible_runs_read",
			Path:        "/api/v1/assistant/machine/control_center/ansible/run_groups/analyze",
			Description: "Analyze all Ansible run groups server-side and return bounded aggregate counts.",
			GroupKeys:   []string{"status_counts", "execution_mode_counts", "failure_policy_counts", "inventory_counts", "credential_counts"},
		}),
	}
	tools = append(tools, credentialTools()...)
	tools = append(tools, inventoryReadTools()...)
	tools = append(tools, variableSetReadTools()...)
	tools = append(tools, customTools()...)
	return tools
}

func credentialTools() []tool.Tool {
	keys := []string{
		"id", "name", "auth_type", "username", "public_key_fingerprint",
		"private_key_configured", "ssh_password_configured", "private_key_passphrase_configured",
		"become_password_configured", "last_used_at", "created_at", "updated_at",
	}
	return readmodule.Build(readmodule.Spec{
		ListTool: "list_ansible_credential_metadata", GetTool: "get_ansible_credential_metadata",
		Scope:    "control_center_ansible_credentials_read",
		BasePath: "/api/v1/assistant/machine/control_center/ansible/credentials", DetailKey: "credential",
		ListDesc:    "List safe Ansible credential metadata and configured flags; never returns authentication material.",
		GetDesc:     "Get safe metadata for one Ansible credential by opaque integer ID; never returns authentication material.",
		SummaryKeys: keys, FullKeys: keys, IDPattern: integerID,
	})
}

func inventoryReadTools() []tool.Tool {
	return readmodule.Build(readmodule.Spec{
		ListTool: "list_ansible_inventories", GetTool: "get_ansible_inventory",
		Scope:    "control_center_ansible_inventories_read",
		BasePath: "/api/v1/assistant/machine/control_center/ansible/inventories", DetailKey: "inventory",
		ListDesc:    "List safe Ansible inventory metadata and approved host-key fingerprints.",
		GetDesc:     "Get one validated inventory without raw known_hosts or credential material.",
		SummaryKeys: []string{"id", "name", "description", "checksum", "lock_version", "default_credential_id", "known_hosts_configured", "host_key_fingerprints", "updated_at"},
		FullKeys:    []string{"id", "name", "description", "checksum", "lock_version", "default_credential_id", "known_hosts_configured", "host_key_fingerprints", "updated_at", "yaml_content", "variable_set_ids", "created_by", "created_at"},
		IDPattern:   integerID, ValidateDetail: validateInventoryDetail,
	})
}

func variableSetReadTools() []tool.Tool {
	return readmodule.Build(readmodule.Spec{
		ListTool: "list_ansible_variable_sets", GetTool: "get_ansible_variable_set",
		Scope:    "control_center_ansible_variables_read",
		BasePath: "/api/v1/assistant/machine/control_center/ansible/variable_sets", DetailKey: "variable_set",
		ListDesc:    "List Ansible variable sets without secret values.",
		GetDesc:     "Get one Ansible variable set; secret values are always null.",
		SummaryKeys: []string{"id", "name", "description", "lock_version", "updated_at"},
		FullKeys:    []string{"id", "name", "description", "lock_version", "updated_at", "created_by", "created_at", "variables"},
		IDPattern:   integerID, ValidateDetail: validateVariableSetDetail,
	})
}

func validateInventoryDetail(detail map[string]json.RawMessage) error {
	var fingerprints map[string]string
	var ids []int64
	if json.Unmarshal(detail["host_key_fingerprints"], &fingerprints) != nil || len(fingerprints) > 1000 ||
		json.Unmarshal(detail["variable_set_ids"], &ids) != nil || len(ids) > 100 {
		return errors.New("invalid inventory projection")
	}
	for host, fingerprint := range fingerprints {
		if len(host) > 512 || len(fingerprint) > 512 {
			return errors.New("invalid inventory projection")
		}
	}
	return nil
}

func validateVariableSetDetail(detail map[string]json.RawMessage) error {
	var variables []map[string]json.RawMessage
	if json.Unmarshal(detail["variables"], &variables) != nil || len(variables) > 10_000 {
		return errors.New("invalid variable projection")
	}
	keys := []string{"id", "name", "value_type", "secret", "configured", "value", "position", "lock_version"}
	for _, variable := range variables {
		if !codec.ExactKeys(variable, keys) {
			return errors.New("invalid variable projection")
		}
		var secret bool
		if json.Unmarshal(variable["secret"], &secret) != nil {
			return errors.New("invalid variable projection")
		}
		if secret && string(variable["value"]) != "null" {
			return errors.New("secret variable value exposed")
		}
	}
	return nil
}
