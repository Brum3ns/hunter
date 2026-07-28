// Package validation provides the validation-result and draft-validation MCP
// tools, which validate Whiterabbit/Ansible drafts without saving or executing
// them and fetch a validation result bound to the turn.
package validation

import (
	"encoding/json"
	"net/url"

	"hunter.local/assistant/mcp/internal/codec"
	"hunter.local/assistant/mcp/internal/tool"
)

const maxRequestBytes = 64 << 10

type Module struct{}

func (Module) Tools() []tool.Tool {
	return []tool.Tool{
		{
			Name:         "get_validation_result",
			Description:  "Return a validation result bound to this turn.",
			InputSchema:  validationResultSchema,
			OutputSchema: tool.ResultSchema,
			Decode:       decodeValidationResult,
			BuildRequest: buildValidationResult,
			Validate:     func(p []byte) error { return validateOutput("get_validation_result", p) },
		},
		{
			Name:         "validate_whiterabbit_draft",
			Description:  "Validate a Whiterabbit draft without saving or sending it.",
			InputSchema:  whiterabbitSchema,
			OutputSchema: tool.ResultSchema,
			Decode:       decodeWhiterabbit,
			BuildRequest: buildDraft("whiterabbit_template"),
			Validate:     func(p []byte) error { return validateOutput("validate_whiterabbit_draft", p) },
		},
		{
			Name:         "validate_ansible_draft",
			Description:  "Validate an Ansible draft without saving or executing it.",
			InputSchema:  ansibleSchema,
			OutputSchema: tool.ResultSchema,
			Decode:       decodeAnsible,
			BuildRequest: buildDraft("ansible_playbook"),
			Validate:     func(p []byte) error { return validateOutput("validate_ansible_draft", p) },
		},
	}
}

func decodeValidationResult(args []byte) (tool.Request, error) {
	var in validationResultInput
	if err := codec.DecodeClosed(args, &in); err != nil || !codec.SafeID.MatchString(in.ID) {
		return tool.Request{}, codec.ErrInvalid
	}
	return tool.Request{Payload: in}, nil
}

func buildValidationResult(req tool.Request) (tool.Call, error) {
	in := req.Payload.(validationResultInput)
	return tool.Call{
		Method: "GET",
		Path:   "/api/v1/assistant/machine/validation_results/" + url.PathEscape(in.ID),
	}, nil
}

func decodeWhiterabbit(args []byte) (tool.Request, error) {
	var in whiterabbitInput
	if err := codec.DecodeClosed(args, &in); err != nil || validateWhiterabbit(in) != nil {
		return tool.Request{}, codec.ErrInvalid
	}
	return tool.Request{Payload: in}, nil
}

func decodeAnsible(args []byte) (tool.Request, error) {
	var in ansibleInput
	if err := codec.DecodeClosed(args, &in); err != nil || validateAnsible(in) != nil {
		return tool.Request{}, codec.ErrInvalid
	}
	return tool.Request{Payload: in}, nil
}

func buildDraft(artifactType string) func(tool.Request) (tool.Call, error) {
	return func(req tool.Request) (tool.Call, error) {
		body, err := json.Marshal(req.Payload)
		if err != nil || len(body) > maxRequestBytes {
			return tool.Call{}, codec.ErrInvalid
		}
		return tool.Call{
			Method: "POST",
			Path:   "/api/v1/assistant/machine/validations/" + artifactType,
			Body:   body,
		}, nil
	}
}
