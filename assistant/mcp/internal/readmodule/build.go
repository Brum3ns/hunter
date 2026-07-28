package readmodule

import (
	"encoding/json"
	"net/url"
	"regexp"
	"strconv"
	"strings"

	"hunter.local/assistant/mcp/internal/codec"
	"hunter.local/assistant/mcp/internal/tool"
)

// Build returns the module's two tools.
func Build(spec Spec) []tool.Tool {
	idPattern := spec.IDPattern
	if idPattern == nil {
		idPattern = codec.SafeID
	}
	return []tool.Tool{
		{
			Name: spec.ListTool, Description: spec.ListDesc,
			InputSchema: listSchema(spec), OutputSchema: tool.ResultSchema,
			Scope:        spec.Scope,
			Decode:       decodeList(spec),
			BuildRequest: buildList(spec),
			Validate:     validateList(spec),
		},
		{
			Name: spec.GetTool, Description: spec.GetDesc,
			InputSchema: getSchema(idPattern), OutputSchema: tool.ResultSchema,
			Scope:        spec.Scope,
			Decode:       decodeGet(idPattern),
			BuildRequest: buildGet(spec),
			Validate:     validateGet(spec),
		},
	}
}

func listSchema(spec Spec) json.RawMessage {
	props := map[string]any{
		"page":  map[string]any{"type": "integer", "minimum": 1, "maximum": 100000},
		"limit": map[string]any{"type": "integer", "minimum": 1, "maximum": spec.maxItems()},
	}
	for _, f := range spec.ListFields {
		if f.Kind == "int" {
			m := map[string]any{"type": "integer"}
			if f.Min != 0 || f.Max != 0 {
				m["minimum"], m["maximum"] = f.Min, f.Max
			}
			props[f.Name] = m
			continue
		}
		m := map[string]any{"type": "string"}
		if f.MaxLen > 0 {
			m["maxLength"] = f.MaxLen
		}
		props[f.Name] = m
	}
	schema := map[string]any{"type": "object", "additionalProperties": false, "properties": props}
	out, _ := json.Marshal(schema)
	return out
}

func getSchema(idPattern *regexp.Regexp) json.RawMessage {
	schema := map[string]any{
		"type": "object", "additionalProperties": false, "required": []string{"id"},
		"properties": map[string]any{
			"id": map[string]any{"type": "string", "minLength": 1, "maxLength": 255, "pattern": idPattern.String()},
		},
	}
	out, _ := json.Marshal(schema)
	return out
}

// decodeList closed-decodes into a raw map, then rejects any key outside the
// allowed set and any value whose JSON type is wrong for its field.
func decodeList(spec Spec) func([]byte) (tool.Request, error) {
	allowed := map[string]string{"page": "int", "limit": "int"}
	for _, f := range spec.ListFields {
		allowed[f.Name] = f.Kind
	}
	return func(args []byte) (tool.Request, error) {
		var raw map[string]json.RawMessage
		if err := codec.DecodeClosed(args, &raw); err != nil {
			return tool.Request{}, codec.ErrInvalid
		}
		for key, val := range raw {
			kind, ok := allowed[key]
			if !ok || !typeMatches(kind, val) {
				return tool.Request{}, codec.ErrInvalid
			}
		}
		return tool.Request{Payload: raw}, nil
	}
}

func typeMatches(kind string, val json.RawMessage) bool {
	trimmed := strings.TrimSpace(string(val))
	switch kind {
	case "int":
		_, err := strconv.Atoi(trimmed)
		return err == nil
	case "string":
		return len(trimmed) > 0 && trimmed[0] == '"'
	}
	return false
}

func buildList(spec Spec) func(tool.Request) (tool.Call, error) {
	return func(req tool.Request) (tool.Call, error) {
		raw := req.Payload.(map[string]json.RawMessage)
		values := url.Values{}
		for key, val := range raw {
			values.Set(key, scalarString(val))
		}
		path := spec.BasePath
		if enc := values.Encode(); enc != "" {
			path += "?" + enc
		}
		return tool.Call{Method: "GET", Path: path}, nil
	}
}

// scalarString renders a validated string/int raw value as its query text.
func scalarString(val json.RawMessage) string {
	trimmed := strings.TrimSpace(string(val))
	if len(trimmed) > 0 && trimmed[0] == '"' {
		var s string
		_ = json.Unmarshal(val, &s)
		return s
	}
	return trimmed
}

type getInput struct {
	ID string `json:"id"`
}

func decodeGet(idPattern *regexp.Regexp) func([]byte) (tool.Request, error) {
	return func(args []byte) (tool.Request, error) {
		var in getInput
		if err := codec.DecodeClosed(args, &in); err != nil || !idPattern.MatchString(in.ID) {
			return tool.Request{}, codec.ErrInvalid
		}
		return tool.Request{Payload: in}, nil
	}
}

func buildGet(spec Spec) func(tool.Request) (tool.Call, error) {
	return func(req tool.Request) (tool.Call, error) {
		in := req.Payload.(getInput)
		return tool.Call{Method: "GET", Path: spec.BasePath + "/" + url.PathEscape(in.ID)}, nil
	}
}
