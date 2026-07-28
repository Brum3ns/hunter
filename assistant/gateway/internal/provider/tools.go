package provider

import "slices"

type ToolDefinition struct {
	Name        string
	Description string
	Schema      map[string]any
}

func FixedToolNames() []string {
	names := make([]string, 0, len(fixedTools()))
	for _, tool := range fixedTools() {
		names = append(names, tool.Name)
	}
	slices.Sort(names)
	return names
}

func fixedTools() []ToolDefinition {
	resource := map[string]any{
		"type": "object", "additionalProperties": false, "required": []string{"type", "id"},
		"properties": map[string]any{
			"type": map[string]any{"type": "string", "enum": []string{"program", "target", "cve", "vulnerability", "whiterabbit_template", "ansible_playbook"}},
			"id":   map[string]any{"type": "string", "minLength": 1, "maxLength": 255, "pattern": "^[A-Za-z0-9][A-Za-z0-9._:-]*$"},
		},
	}
	artifact := map[string]any{
		"type": "object", "additionalProperties": false, "required": []string{"artifact_type"},
		"properties": map[string]any{"artifact_type": map[string]any{"type": "string", "enum": []string{"whiterabbit_template", "ansible_playbook"}}},
	}
	validationResult := map[string]any{
		"type": "object", "additionalProperties": false, "required": []string{"id"},
		"properties": map[string]any{"id": map[string]any{"type": "string", "minLength": 1, "maxLength": 255, "pattern": "^[A-Za-z0-9][A-Za-z0-9._:-]*$"}},
	}
	whiterabbit := map[string]any{
		"type": "object", "additionalProperties": false, "required": []string{"draft"},
		"properties": map[string]any{"draft": map[string]any{
			"type": "object", "additionalProperties": false, "required": []string{"name", "kind", "description", "commands"},
			"properties": map[string]any{
				"name":        map[string]any{"type": "string", "minLength": 1, "maxLength": 200},
				"kind":        map[string]any{"type": "string", "maxLength": 40},
				"description": map[string]any{"type": "string", "maxLength": 4000},
				"commands": map[string]any{"type": "array", "maxItems": 50, "items": map[string]any{
					"type": "object", "additionalProperties": false, "required": []string{"command", "args", "operator"},
					"properties": map[string]any{
						"command":  map[string]any{"type": "string", "minLength": 1, "maxLength": 255},
						"args":     map[string]any{"type": "array", "maxItems": 200, "items": map[string]any{"type": "string", "maxLength": 4096}},
						"operator": map[string]any{"type": "string", "maxLength": 4},
					},
				}},
			},
		}},
	}
	ansible := map[string]any{
		"type": "object", "additionalProperties": false, "required": []string{"draft"},
		"properties": map[string]any{"draft": map[string]any{
			"type": "object", "additionalProperties": false, "required": []string{"name", "source"},
			"properties": map[string]any{
				"name":   map[string]any{"type": "string", "minLength": 1, "maxLength": 200},
				"source": map[string]any{"type": "string", "minLength": 1, "maxLength": 65536},
			},
		}},
	}
	return []ToolDefinition{
		{Name: "get_artifact_example", Description: "Return one explicitly granted sanitized artifact example.", Schema: resource},
		{Name: "get_authoring_policy", Description: "Return non-secret policy for one artifact type.", Schema: artifact},
		{Name: "get_selected_context", Description: "Return one explicitly granted sanitized context record.", Schema: resource},
		{Name: "get_validation_result", Description: "Return one validation result bound to this turn.", Schema: validationResult},
		{Name: "validate_ansible_draft", Description: "Validate an Ansible draft without saving or executing it.", Schema: ansible},
		{Name: "validate_whiterabbit_draft", Description: "Validate a Whiterabbit draft without saving or sending it.", Schema: whiterabbit},
	}
}
