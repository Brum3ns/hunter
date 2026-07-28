// Package targets provides the read-only list_targets and get_target MCP tools.
package targets

import (
	"net/url"

	"hunter.local/assistant/mcp/internal/codec"
	"hunter.local/assistant/mcp/internal/tool"
)

const basePath = "/api/v1/assistant/machine/targets"

type Module struct{}

func (Module) Tools() []tool.Tool {
	return []tool.Tool{
		{
			Name:         "list_targets",
			Description:  "List and count alive targets, optionally filtered by query, program, or status.",
			InputSchema:  listSchema,
			OutputSchema: tool.ResultSchema,
			Scope:        "targets",
			Decode:       decodeList,
			BuildRequest: buildList,
			Validate:     validateListOutput,
		},
		{
			Name:         "get_target",
			Description:  "Return the full record for one target by id.",
			InputSchema:  getSchema,
			OutputSchema: tool.ResultSchema,
			Scope:        "targets",
			Decode:       decodeGet,
			BuildRequest: buildGet,
			Validate:     validateGetOutput,
		},
	}
}

func decodeList(args []byte) (tool.Request, error) {
	var in listInput
	if err := codec.DecodeClosed(args, &in); err != nil {
		return tool.Request{}, err
	}
	return tool.Request{Payload: in}, nil
}

func buildList(req tool.Request) (tool.Call, error) {
	in := req.Payload.(listInput)
	path := basePath
	if q := listQuery(in); q != "" {
		path += "?" + q
	}
	return tool.Call{Method: "GET", Path: path}, nil
}

func decodeGet(args []byte) (tool.Request, error) {
	var in getInput
	if err := codec.DecodeClosed(args, &in); err != nil || !validID(in.ID) {
		return tool.Request{}, codec.ErrInvalid
	}
	return tool.Request{Payload: in}, nil
}

func buildGet(req tool.Request) (tool.Call, error) {
	in := req.Payload.(getInput)
	return tool.Call{Method: "GET", Path: basePath + "/" + url.PathEscape(in.ID)}, nil
}
