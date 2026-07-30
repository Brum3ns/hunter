// Package ccwrite provides the two approval-free Control Center create tools:
// create_whiterabbit_template and create_ansible_playbook. Both are
// create-only (never edit, delete, or run) and are gated by dedicated write
// scopes; the Rails endpoint runs the mandatory fail-closed content
// validators before persisting.
package ccwrite

import (
	"encoding/json"

	"hunter.local/assistant/mcp/internal/codec"
	"hunter.local/assistant/mcp/internal/tool"
)

const maxRequestBytes = 64 << 10

type Module struct{}

func (Module) Tools() []tool.Tool {
	return []tool.Tool{
		{
			Name: "create_whiterabbit_template",
			Description: "Create a new Whiterabbit template. Create-only: never edits, deletes, or runs " +
				"anything. The content is validated fail-closed before it is saved.",
			InputSchema:  templateSchema,
			OutputSchema: tool.ResultSchema,
			Scope:        "control_center_templates_write",
			Decode:       decodeTemplate,
			BuildRequest: buildCreate("/api/v1/assistant/machine/control_center/templates"),
			Validate:     func(payload []byte) error { return validateCreateOutput(payload, "template") },
		},
		{
			Name: "create_ansible_playbook",
			Description: "Create a new Ansible playbook. Create-only: never edits, deletes, or runs " +
				"anything. The content is validated fail-closed before it is saved.",
			InputSchema:  playbookSchema,
			OutputSchema: tool.ResultSchema,
			Scope:        "control_center_ansible_write",
			Decode:       decodePlaybook,
			BuildRequest: buildCreate("/api/v1/assistant/machine/control_center/ansible/playbooks"),
			Validate:     func(payload []byte) error { return validateCreateOutput(payload, "playbook") },
		},
	}
}

func decodeTemplate(args []byte) (tool.Request, error) {
	var in templateInput
	if err := codec.DecodeClosed(args, &in); err != nil || validateTemplateInput(in) != nil {
		return tool.Request{}, codec.ErrInvalid
	}
	return tool.Request{Payload: in}, nil
}

func decodePlaybook(args []byte) (tool.Request, error) {
	var in playbookInput
	if err := codec.DecodeClosed(args, &in); err != nil || validatePlaybookInput(in) != nil {
		return tool.Request{}, codec.ErrInvalid
	}
	return tool.Request{Payload: in}, nil
}

// buildCreate marshals the decoded payload as the POST body for path, enforcing
// the shared 64 KiB request cap.
func buildCreate(path string) func(tool.Request) (tool.Call, error) {
	return func(req tool.Request) (tool.Call, error) {
		body, err := json.Marshal(req.Payload)
		if err != nil || len(body) > maxRequestBytes {
			return tool.Call{}, codec.ErrInvalid
		}
		return tool.Call{Method: "POST", Path: path, Body: body}, nil
	}
}
