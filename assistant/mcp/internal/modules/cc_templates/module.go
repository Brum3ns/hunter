// Package cc_templates provides the read-only list_templates and get_template
// MCP tools over Control Center's Whiterabbit command templates.
package cc_templates

import (
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
		GetDesc:  "Return the full record for one Control Center template by id.",
		ListFields: []readmodule.ListField{
			{Name: "kind", Kind: "string", MaxLen: 40},
		},
		SummaryKeys: []string{"id", "name", "kind", "description", "tags", "updated_at"},
		FullKeys: []string{
			"id", "name", "kind", "description", "tags", "updated_at",
			"output", "commands", "target", "created_at",
		},
		IDPattern: idPattern,
	})
}
