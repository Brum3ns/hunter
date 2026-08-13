// Package ccwrite provides the four approval-free Control Center authoring
// tools. Creates never overwrite. Edits require an explicit artifact ID and
// optimistic lock version. No tool deletes, runs, schedules, or executes.
package ccwrite

import (
	"encoding/json"
	"fmt"

	"hunter.local/assistant/mcp/internal/codec"
	"hunter.local/assistant/mcp/internal/tool"
)

const maxRequestBytes = 512 << 10

type Module struct{}

func (Module) Tools() []tool.Tool {
	return []tool.Tool{
		{
			Name: "create_whiterabbit_template",
			Description: "Create a new validated Whiterabbit template in Control Center without a confirmation prompt. " +
				"Never overwrites, edits, deletes, or runs an existing template.",
			InputSchema: templateSchema, OutputSchema: resultSchema("template"),
			Scope: "control_center_templates_write", WriteScope: true,
			Decode: decodeTemplate, BuildRequest: buildCreate("/api/v1/assistant/machine/control_center/templates"),
			Validate: func(payload []byte) error { return validateCreateOutput(payload, "template") },
		},
		{
			Name: "create_ansible_playbook",
			Description: "Create a new validated Ansible playbook in Control Center without a confirmation prompt. " +
				"Never overwrites, edits, deletes, or runs an existing playbook.",
			InputSchema: playbookSchema, OutputSchema: resultSchema("playbook"),
			Scope: "control_center_ansible_write", WriteScope: true,
			Decode: decodePlaybook, BuildRequest: buildCreate("/api/v1/assistant/machine/control_center/ansible/playbooks"),
			Validate: func(payload []byte) error { return validateCreateOutput(payload, "playbook") },
		},
		{
			Name: "edit_whiterabbit_template",
			Description: "Edit an existing Whiterabbit template by ID after an explicit user edit request. " +
				"Requires its current lock version, validates the complete merged template, and never deletes or runs it.",
			InputSchema: templateEditSchema, OutputSchema: resultSchema("template"),
			Scope: "control_center_templates_edit", WriteScope: true,
			Decode: decodeTemplateEdit, BuildRequest: buildEdit("/api/v1/assistant/machine/control_center/templates/%d"),
			Validate: func(payload []byte) error { return validateCreateOutput(payload, "template") },
		},
		{
			Name: "edit_ansible_playbook",
			Description: "Edit an existing Ansible playbook by ID after an explicit user edit request. " +
				"Requires its current lock version, validates the complete merged playbook, and never deletes or runs it.",
			InputSchema: playbookEditSchema, OutputSchema: resultSchema("playbook"),
			Scope: "control_center_ansible_edit", WriteScope: true,
			Decode: decodePlaybookEdit, BuildRequest: buildEdit("/api/v1/assistant/machine/control_center/ansible/playbooks/%d"),
			Validate: func(payload []byte) error { return validateCreateOutput(payload, "playbook") },
		},
	}
}

func decodeTemplate(args []byte) (tool.Request, error) {
	var in templateInput
	if err := codec.DecodeClosed(args, &in); err != nil || validateTemplateInput(in) != nil {
		return tool.Request{}, codec.ErrInvalid
	}
	normalizeCommands(in.Template.Commands)
	return tool.Request{Payload: in}, nil
}

func decodePlaybook(args []byte) (tool.Request, error) {
	var in playbookInput
	if err := codec.DecodeClosed(args, &in); err != nil || validatePlaybookInput(in) != nil {
		return tool.Request{}, codec.ErrInvalid
	}
	return tool.Request{Payload: in}, nil
}

func decodeTemplateEdit(args []byte) (tool.Request, error) {
	allowed := []string{"name", "kind", "tags", "description", "output", "commands", "target"}
	if !nonNullClosedObject(args, []string{"id", "expected_lock_version", "changes"}, "changes", allowed) {
		return tool.Request{}, codec.ErrInvalid
	}
	var in templateEditInput
	if err := codec.DecodeClosed(args, &in); err != nil || validateTemplateChanges(in) != nil {
		return tool.Request{}, codec.ErrInvalid
	}
	if in.Changes.Commands != nil {
		normalizeCommands(*in.Changes.Commands)
	}
	return tool.Request{Payload: in}, nil
}

func normalizeCommands(commands []templateCommand) {
	for index := range commands {
		if commands[index].Args == nil {
			commands[index].Args = []string{}
		}
	}
}

func decodePlaybookEdit(args []byte) (tool.Request, error) {
	allowed := []string{"name", "description", "source", "variable_set_ids"}
	if !nonNullClosedObject(args, []string{"id", "expected_lock_version", "changes"}, "changes", allowed) {
		return tool.Request{}, codec.ErrInvalid
	}
	var in playbookEditInput
	if err := codec.DecodeClosed(args, &in); err != nil || validatePlaybookChanges(in) != nil {
		return tool.Request{}, codec.ErrInvalid
	}
	return tool.Request{Payload: in}, nil
}

func buildCreate(path string) func(tool.Request) (tool.Call, error) {
	return func(req tool.Request) (tool.Call, error) {
		body, err := json.Marshal(req.Payload)
		if err != nil || len(body) > maxRequestBytes {
			return tool.Call{}, codec.ErrInvalid
		}
		return tool.Call{Method: "POST", Path: path, Body: body}, nil
	}
}

func buildEdit(pathFormat string) func(tool.Request) (tool.Call, error) {
	return func(req tool.Request) (tool.Call, error) {
		var id int64
		var body any
		switch in := req.Payload.(type) {
		case templateEditInput:
			id = in.ID
			body = struct {
				ExpectedLockVersion int64           `json:"expected_lock_version"`
				Changes             templateChanges `json:"changes"`
			}{in.ExpectedLockVersion, in.Changes}
		case playbookEditInput:
			id = in.ID
			body = struct {
				ExpectedLockVersion int64           `json:"expected_lock_version"`
				Changes             playbookChanges `json:"changes"`
			}{in.ExpectedLockVersion, in.Changes}
		default:
			return tool.Call{}, codec.ErrInvalid
		}
		encoded, err := json.Marshal(body)
		if err != nil || len(encoded) > maxRequestBytes {
			return tool.Call{}, codec.ErrInvalid
		}
		return tool.Call{Method: "PATCH", Path: fmt.Sprintf(pathFormat, id), Body: encoded}, nil
	}
}
