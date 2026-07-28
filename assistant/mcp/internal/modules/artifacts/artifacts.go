// Package artifacts provides the get_artifact_example MCP tool, which returns one
// explicitly granted sanitized artifact example (whiterabbit or ansible).
package artifacts

import (
	"net/url"

	"hunter.local/assistant/mcp/internal/codec"
	"hunter.local/assistant/mcp/internal/resource"
	"hunter.local/assistant/mcp/internal/tool"
)

type Module struct{}

func (Module) Tools() []tool.Tool {
	return []tool.Tool{{
		Name:             "get_artifact_example",
		Description:      "Return one explicitly granted sanitized artifact example.",
		InputSchema:      resource.Schema,
		OutputSchema:     tool.ResultSchema,
		RequiresResource: true,
		Decode:           decode,
		BuildRequest:     buildRequest,
		Validate:         func(p []byte) error { return validateKeys(p, []string{"correlation_id", "artifact"}) },
	}}
}

func decode(args []byte) (tool.Request, error) {
	in, err := resource.Decode(args)
	if err != nil {
		return tool.Request{}, err
	}
	if in.Type != "whiterabbit_template" && in.Type != "ansible_playbook" {
		return tool.Request{}, codec.ErrInvalid
	}
	return tool.Request{Payload: in, Resource: &tool.Resource{Type: in.Type, ID: in.ID}}, nil
}

func buildRequest(req tool.Request) (tool.Call, error) {
	r := req.Resource
	return tool.Call{
		Method: "GET",
		Path:   "/api/v1/assistant/machine/artifacts/" + url.PathEscape(r.Type) + "/" + url.PathEscape(r.ID),
	}, nil
}
