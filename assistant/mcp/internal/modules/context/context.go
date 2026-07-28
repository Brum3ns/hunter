// Package context provides the get_selected_context MCP tool, which returns one
// explicitly granted sanitized Hunter context record.
package context

import (
	"net/url"

	"hunter.local/assistant/mcp/internal/resource"
	"hunter.local/assistant/mcp/internal/tool"
)

type Module struct{}

func (Module) Tools() []tool.Tool {
	return []tool.Tool{{
		Name:             "get_selected_context",
		Description:      "Return one explicitly granted sanitized Hunter context record.",
		InputSchema:      resource.Schema,
		OutputSchema:     tool.ResultSchema,
		RequiresResource: true,
		Decode:           decode,
		BuildRequest:     buildRequest,
		Validate:         func(p []byte) error { return validateKeys(p, []string{"correlation_id", "context"}) },
	}}
}

func decode(args []byte) (tool.Request, error) {
	in, err := resource.Decode(args)
	if err != nil {
		return tool.Request{}, err
	}
	return tool.Request{Payload: in, Resource: &tool.Resource{Type: in.Type, ID: in.ID}}, nil
}

func buildRequest(req tool.Request) (tool.Call, error) {
	r := req.Resource
	return tool.Call{
		Method: "GET",
		Path:   "/api/v1/assistant/machine/contexts/" + url.PathEscape(r.Type) + "/" + url.PathEscape(r.ID),
	}, nil
}
