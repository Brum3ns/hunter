package ccwrite

import (
	"bytes"
	"encoding/json"
	"errors"
	"regexp"
	"strings"

	"hunter.local/assistant/mcp/internal/codec"
)

var errRejected = errors.New("tool response rejected")

var uuidPattern = regexp.MustCompile(
	`^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)

type templateInput struct {
	Template templateDraft `json:"template"`
}

type templateDraft struct {
	Name        string            `json:"name"`
	Kind        string            `json:"kind"`
	Tags        []string          `json:"tags,omitempty"`
	Description string            `json:"description,omitempty"`
	Output      string            `json:"output,omitempty"`
	Commands    []templateCommand `json:"commands"`
	Target      *templateTarget   `json:"target,omitempty"`
}

type templateCommand struct {
	Command  string   `json:"command"`
	Operator string   `json:"operator"`
	Args     []string `json:"args"`
}

type templateTarget struct {
	Type      string `json:"type,omitempty"`
	Separator string `json:"separator,omitempty"`
	Output    string `json:"output,omitempty"`
}

type templateChanges struct {
	Name        *string            `json:"name,omitempty"`
	Kind        *string            `json:"kind,omitempty"`
	Tags        *[]string          `json:"tags,omitempty"`
	Description *string            `json:"description,omitempty"`
	Output      *string            `json:"output,omitempty"`
	Commands    *[]templateCommand `json:"commands,omitempty"`
	Target      *templateTarget    `json:"target,omitempty"`
}

type templateEditInput struct {
	ID                  int64           `json:"id"`
	ExpectedLockVersion int64           `json:"expected_lock_version"`
	Changes             templateChanges `json:"changes"`
}

type playbookInput struct {
	Playbook playbookDraft `json:"playbook"`
}

type playbookDraft struct {
	Name           string  `json:"name"`
	Description    string  `json:"description,omitempty"`
	Source         string  `json:"source"`
	VariableSetIDs []int64 `json:"variable_set_ids,omitempty"`
}

type playbookChanges struct {
	Name           *string  `json:"name,omitempty"`
	Description    *string  `json:"description,omitempty"`
	Source         *string  `json:"source,omitempty"`
	VariableSetIDs *[]int64 `json:"variable_set_ids,omitempty"`
}

type playbookEditInput struct {
	ID                  int64           `json:"id"`
	ExpectedLockVersion int64           `json:"expected_lock_version"`
	Changes             playbookChanges `json:"changes"`
}

func nonNullClosedObject(raw []byte, exact []string, objectKey string, allowed []string) bool {
	var root map[string]json.RawMessage
	if codec.DecodeRawClosed(raw, &root) != nil || !codec.ExactKeys(root, exact) {
		return false
	}
	var object map[string]json.RawMessage
	if codec.DecodeRawClosed(root[objectKey], &object) != nil || len(object) == 0 {
		return false
	}
	for key, value := range object {
		if !contains(allowed, key) || bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			return false
		}
	}
	return true
}

func contains(values []string, candidate string) bool {
	for _, value := range values {
		if value == candidate {
			return true
		}
	}
	return false
}

func validateTemplateInput(in templateInput) error {
	if strings.TrimSpace(in.Template.Name) == "" || len(in.Template.Name) > 200 ||
		(in.Template.Kind != "cmdscript" && in.Template.Kind != "workflow") ||
		len(in.Template.Description) > 4000 || len(in.Template.Output) > 4000 ||
		!validStrings(in.Template.Tags, 50, 200) || !validCommands(in.Template.Commands) ||
		!validTarget(in.Template.Target) {
		return codec.ErrInvalid
	}
	return nil
}

func validateTemplateChanges(in templateEditInput) error {
	if in.ID <= 0 || in.ExpectedLockVersion < 0 || templateChangesEmpty(in.Changes) {
		return codec.ErrInvalid
	}
	if in.Changes.Name != nil && (strings.TrimSpace(*in.Changes.Name) == "" || len(*in.Changes.Name) > 200) {
		return codec.ErrInvalid
	}
	if in.Changes.Kind != nil && *in.Changes.Kind != "cmdscript" && *in.Changes.Kind != "workflow" {
		return codec.ErrInvalid
	}
	if in.Changes.Description != nil && len(*in.Changes.Description) > 4000 ||
		in.Changes.Output != nil && len(*in.Changes.Output) > 4000 ||
		in.Changes.Tags != nil && !validStrings(*in.Changes.Tags, 50, 200) ||
		in.Changes.Commands != nil && !validCommands(*in.Changes.Commands) ||
		!validTarget(in.Changes.Target) {
		return codec.ErrInvalid
	}
	return nil
}

func templateChangesEmpty(changes templateChanges) bool {
	return changes.Name == nil && changes.Kind == nil && changes.Tags == nil &&
		changes.Description == nil && changes.Output == nil && changes.Commands == nil && changes.Target == nil
}

func validCommands(commands []templateCommand) bool {
	if len(commands) == 0 || len(commands) > 50 {
		return false
	}
	for _, command := range commands {
		if strings.TrimSpace(command.Command) == "" || len(command.Command) > 255 ||
			!contains([]string{"", "|", "&&", "||"}, command.Operator) || len(command.Args) > 200 {
			return false
		}
		for _, argument := range command.Args {
			if len(argument) > 4096 {
				return false
			}
		}
	}
	return true
}

func validTarget(target *templateTarget) bool {
	return target == nil || len(target.Type) <= 100 && len(target.Separator) <= 20 && len(target.Output) <= 4000
}

func validStrings(values []string, maxItems, maxLength int) bool {
	if len(values) > maxItems {
		return false
	}
	for _, value := range values {
		if len(value) > maxLength {
			return false
		}
	}
	return true
}

func validatePlaybookInput(in playbookInput) error {
	if strings.TrimSpace(in.Playbook.Name) == "" || len(in.Playbook.Name) > 200 ||
		strings.TrimSpace(in.Playbook.Source) == "" || len(in.Playbook.Source) > 65536 ||
		len(in.Playbook.Description) > 4000 || !validIDs(in.Playbook.VariableSetIDs) {
		return codec.ErrInvalid
	}
	return nil
}

func validatePlaybookChanges(in playbookEditInput) error {
	if in.ID <= 0 || in.ExpectedLockVersion < 0 || playbookChangesEmpty(in.Changes) {
		return codec.ErrInvalid
	}
	if in.Changes.Name != nil && (strings.TrimSpace(*in.Changes.Name) == "" || len(*in.Changes.Name) > 200) ||
		in.Changes.Source != nil && (strings.TrimSpace(*in.Changes.Source) == "" || len(*in.Changes.Source) > 65536) ||
		in.Changes.Description != nil && len(*in.Changes.Description) > 4000 ||
		in.Changes.VariableSetIDs != nil && !validIDs(*in.Changes.VariableSetIDs) {
		return codec.ErrInvalid
	}
	return nil
}

func playbookChangesEmpty(changes playbookChanges) bool {
	return changes.Name == nil && changes.Description == nil && changes.Source == nil && changes.VariableSetIDs == nil
}

func validIDs(ids []int64) bool {
	if len(ids) > 100 {
		return false
	}
	seen := make(map[int64]struct{}, len(ids))
	for _, id := range ids {
		if id <= 0 {
			return false
		}
		if _, exists := seen[id]; exists {
			return false
		}
		seen[id] = struct{}{}
	}
	return true
}

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
	if codec.DecodeRawClosed(root[artifactKey], &artifact) != nil ||
		!codec.ExactKeys(artifact, []string{"id", "name", "lock_version"}) {
		return errRejected
	}
	var id, lockVersion int64
	var name string
	if json.Unmarshal(artifact["id"], &id) != nil || id <= 0 ||
		json.Unmarshal(artifact["name"], &name) != nil || strings.TrimSpace(name) == "" || len(name) > 200 ||
		json.Unmarshal(artifact["lock_version"], &lockVersion) != nil || lockVersion < 0 {
		return errRejected
	}
	return nil
}
