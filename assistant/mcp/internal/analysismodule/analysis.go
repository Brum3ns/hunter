// Package analysismodule builds dedicated, closed server-side aggregation
// tools. It never accepts a route, method, grouping expression, or operation
// from model input; those remain compile-time module metadata.
package analysismodule

import (
	"encoding/json"
	"errors"

	"hunter.local/assistant/mcp/internal/codec"
	"hunter.local/assistant/mcp/internal/readmodule"
	"hunter.local/assistant/mcp/internal/tool"
)

type Spec struct {
	Name        string
	Scope       string
	Path        string
	Description string
	Fields      []readmodule.ListField
	GroupKeys   []string
}

var errRejected = errors.New("tool response rejected")

func Build(spec Spec) tool.Tool {
	return tool.Tool{
		Name: spec.Name, Scope: spec.Scope, Description: spec.Description,
		InputSchema: schema(spec), OutputSchema: tool.ResultSchema,
		Decode: decode(spec), BuildRequest: build(spec), Validate: validate(spec),
	}
}

func schema(spec Spec) json.RawMessage {
	properties := make(map[string]any, len(spec.Fields))
	for _, field := range spec.Fields {
		definition := map[string]any{"type": field.Kind}
		if field.Kind == "int" {
			definition["type"] = "integer"
			definition["minimum"], definition["maximum"] = field.Min, field.Max
		} else if field.MaxLen > 0 {
			definition["maxLength"] = field.MaxLen
		}
		if field.Description != "" {
			definition["description"] = field.Description
		}
		properties[field.Name] = definition
	}
	encoded, _ := json.Marshal(map[string]any{
		"type": "object", "additionalProperties": false, "properties": properties,
	})
	return encoded
}

func decode(spec Spec) func([]byte) (tool.Request, error) {
	allowed := make(map[string]readmodule.ListField, len(spec.Fields))
	for _, field := range spec.Fields {
		allowed[field.Name] = field
	}
	return func(args []byte) (tool.Request, error) {
		var values map[string]json.RawMessage
		if codec.DecodeClosed(args, &values) != nil {
			return tool.Request{}, codec.ErrInvalid
		}
		for name, raw := range values {
			field, ok := allowed[name]
			if !ok || !matches(field, raw) {
				return tool.Request{}, codec.ErrInvalid
			}
		}
		return tool.Request{Payload: values}, nil
	}
}

func matches(field readmodule.ListField, raw json.RawMessage) bool {
	if field.Kind == "int" {
		var value int
		return json.Unmarshal(raw, &value) == nil && value >= field.Min && value <= field.Max
	}
	var value string
	return json.Unmarshal(raw, &value) == nil && (field.MaxLen == 0 || len(value) <= field.MaxLen)
}

func build(spec Spec) func(tool.Request) (tool.Call, error) {
	return func(request tool.Request) (tool.Call, error) {
		body, err := json.Marshal(request.Payload)
		if err != nil {
			return tool.Call{}, codec.ErrInvalid
		}
		return tool.Call{Method: "POST", Path: spec.Path, Body: body}, nil
	}
}

func validate(spec Spec) func([]byte) error {
	rootKeys := []string{"correlation_id", "count", "analyzed_count", "truncated"}
	rootKeys = append(rootKeys, spec.GroupKeys...)
	return func(payload []byte) error {
		var root map[string]json.RawMessage
		if codec.DecodeRawClosed(payload, &root) != nil || !codec.ExactKeys(root, rootKeys) {
			return errRejected
		}
		var correlationID string
		var count, analyzed int
		var truncated bool
		if json.Unmarshal(root["correlation_id"], &correlationID) != nil ||
			!readmodule.UUIDPattern.MatchString(correlationID) ||
			json.Unmarshal(root["count"], &count) != nil || count < 0 ||
			json.Unmarshal(root["analyzed_count"], &analyzed) != nil || analyzed < 0 || analyzed > 10_000 ||
			json.Unmarshal(root["truncated"], &truncated) != nil || analyzed > count {
			return errRejected
		}
		for _, key := range spec.GroupKeys {
			var groups []map[string]json.RawMessage
			if json.Unmarshal(root[key], &groups) != nil || len(groups) > 100 {
				return errRejected
			}
			for _, group := range groups {
				if !codec.ExactKeys(group, []string{"value", "count"}) ||
					!readmodule.StringValue(group["value"], 512, false) ||
					!readmodule.IntegerValue(group["count"], 1, 10_000, false) {
					return errRejected
				}
			}
		}
		return nil
	}
}
