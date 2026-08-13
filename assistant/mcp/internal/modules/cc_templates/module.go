// Package cc_templates provides the read-only list_templates and get_template
// MCP tools over Control Center's Whiterabbit command templates.
package cc_templates

import (
	"bytes"
	"encoding/json"
	"errors"
	"regexp"

	"hunter.local/assistant/mcp/internal/readmodule"
	"hunter.local/assistant/mcp/internal/tool"
)

// idPattern matches the integer primary key of control_center_templates.
var idPattern = regexp.MustCompile("^[1-9][0-9]{0,18}$")

type Module struct{}

func (Module) Tools() []tool.Tool {
	return readmodule.Build(readmodule.Spec{
		ListTool: "list_templates", GetTool: "get_template", Scope: "control_center_templates",
		BasePath: "/api/v1/assistant/machine/control_center/templates", DetailKey: "template",
		ListDesc: "List and count Control Center Whiterabbit templates, optionally filtered by kind.",
		GetDesc:  "Return the full record for one Control Center template by its integer id.",
		ListFields: []readmodule.ListField{
			{Name: "kind", Kind: "string", MaxLen: 40, Description: "Filter by template kind: cmdscript or workflow."},
		},
		SummaryKeys: []string{"id", "name", "kind", "description", "tags", "lock_version", "created_by", "updated_at"},
		FullKeys: []string{
			"id", "name", "kind", "description", "tags", "lock_version", "created_by", "updated_at",
			"output", "commands", "target", "created_at",
		},
		ValidateDetail: validateDetail,
		IDPattern:      idPattern,
	})
}

func validateDetail(detail map[string]json.RawMessage) error {
	commandKeys := []string{"command", "args", "operator"}
	if !readmodule.BoundedStringArray(detail["tags"], 50, 200) ||
		!readmodule.TypedObjectArray(detail["commands"], commandKeys, 50,
			func(command map[string]json.RawMessage) bool {
				return readmodule.StringValue(command["command"], 255, false) &&
					readmodule.BoundedStringArray(command["args"], 200, 4_096) &&
					readmodule.StringValue(command["operator"], 2, false)
			}) {
		return errors.New("invalid template command projection")
	}
	target := bytes.TrimSpace(detail["target"])
	if !bytes.Equal(target, []byte("null")) &&
		!readmodule.TypedObject(target, []string{"type", "separator", "output"},
			func(target map[string]json.RawMessage) bool {
				return readmodule.StringValue(target["type"], 100, true) &&
					readmodule.StringValue(target["separator"], 20, true) &&
					readmodule.StringValue(target["output"], 4_000, true)
			}) {
		return errors.New("invalid template target projection")
	}
	return nil
}
