package ccwrite

import (
	"encoding/json"
	"errors"
	"regexp"
	"strings"

	"hunter.local/assistant/mcp/internal/codec"
)

var errRejected = errors.New("tool response rejected")

// uuidPattern is the correlation-id shape every create-response envelope carries.
var uuidPattern = regexp.MustCompile(
	`^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)

type templateInput struct {
	Template templateDraft `json:"template"`
}

type templateDraft struct {
	Name        string            `json:"name"`
	Kind        string            `json:"kind"`
	Description string            `json:"description,omitempty"`
	Commands    []templateCommand `json:"commands"`
}

type templateCommand struct {
	Command  string   `json:"command"`
	Operator string   `json:"operator,omitempty"`
	Args     []string `json:"args,omitempty"`
}

type playbookInput struct {
	Playbook playbookDraft `json:"playbook"`
}

type playbookDraft struct {
	Name   string `json:"name"`
	Source string `json:"source"`
}

// validateTemplateInput is the Go pre-check mirroring the JSON schema bounds
// (belt-and-suspenders, same as the validation module's whiterabbit draft check).
func validateTemplateInput(in templateInput) error {
	if strings.TrimSpace(in.Template.Name) == "" || len(in.Template.Name) > 200 {
		return codec.ErrInvalid
	}
	if in.Template.Kind != "cmdscript" && in.Template.Kind != "workflow" {
		return codec.ErrInvalid
	}
	if len(in.Template.Description) > 4000 {
		return codec.ErrInvalid
	}
	if len(in.Template.Commands) == 0 || len(in.Template.Commands) > 50 {
		return codec.ErrInvalid
	}
	for _, command := range in.Template.Commands {
		if strings.TrimSpace(command.Command) == "" || len(command.Command) > 255 ||
			len(command.Operator) > 4 || len(command.Args) > 200 {
			return codec.ErrInvalid
		}
		for _, argument := range command.Args {
			if len(argument) > 4096 {
				return codec.ErrInvalid
			}
		}
	}
	return nil
}

func validatePlaybookInput(in playbookInput) error {
	if strings.TrimSpace(in.Playbook.Name) == "" || len(in.Playbook.Name) > 200 {
		return codec.ErrInvalid
	}
	if strings.TrimSpace(in.Playbook.Source) == "" || len(in.Playbook.Source) > 65536 {
		return codec.ErrInvalid
	}
	return nil
}

// validateCreateOutput enforces the closed {correlation_id, <artifact>:{id,name}}
// envelope a create endpoint returns, mirroring the readmodule validateGet
// exact-keys style.
func validateCreateOutput(payload []byte, artifactKey string) error {
	var root map[string]json.RawMessage
	if err := codec.DecodeRawClosed(payload, &root); err != nil {
		return err
	}
	if !codec.ExactKeys(root, []string{"correlation_id", artifactKey}) {
		return errRejected
	}
	var correlationID string
	if json.Unmarshal(root["correlation_id"], &correlationID) != nil || !uuidPattern.MatchString(correlationID) {
		return errRejected
	}
	var artifact map[string]json.RawMessage
	if codec.DecodeRawClosed(root[artifactKey], &artifact) != nil {
		return errRejected
	}
	if !codec.ExactKeys(artifact, []string{"id", "name"}) {
		return errRejected
	}
	var id int64
	if json.Unmarshal(artifact["id"], &id) != nil || id <= 0 {
		return errRejected
	}
	var name string
	if json.Unmarshal(artifact["name"], &name) != nil || strings.TrimSpace(name) == "" || len(name) > 200 {
		return errRejected
	}
	return nil
}
