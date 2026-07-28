// Package policies provides the get_authoring_policy MCP tool, which returns the
// non-secret authoring policy for one artifact type.
package policies

import (
	"encoding/json"
	"net/url"

	"hunter.local/assistant/mcp/internal/codec"
	"hunter.local/assistant/mcp/internal/tool"
)

// schema is the advertised input schema (the artifactSchema from the old catalog).
var schema = json.RawMessage(`{
    "type":"object",
    "additionalProperties":false,
    "required":["artifact_type"],
    "properties":{"artifact_type":{"type":"string","enum":["whiterabbit_template","ansible_playbook"]}}
  }`)

type input struct {
	ArtifactType string `json:"artifact_type"`
}

type Module struct{}

func (Module) Tools() []tool.Tool {
	return []tool.Tool{{
		Name:         "get_authoring_policy",
		Description:  "Return the non-secret authoring policy for one artifact type.",
		InputSchema:  schema,
		OutputSchema: tool.ResultSchema,
		Decode:       decode,
		BuildRequest: buildRequest,
		Validate:     func(p []byte) error { return validateKeys(p, []string{"correlation_id", "policy"}) },
	}}
}

func decode(args []byte) (tool.Request, error) {
	var in input
	if err := codec.DecodeClosed(args, &in); err != nil || !validArtifactType(in.ArtifactType) {
		return tool.Request{}, codec.ErrInvalid
	}
	return tool.Request{Payload: in}, nil
}

func buildRequest(req tool.Request) (tool.Call, error) {
	in := req.Payload.(input)
	return tool.Call{
		Method: "GET",
		Path:   "/api/v1/assistant/machine/policies/" + url.PathEscape(in.ArtifactType),
	}, nil
}
