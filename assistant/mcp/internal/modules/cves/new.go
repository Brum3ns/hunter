package cves

import (
	"encoding/json"
	"errors"
	"net/url"
	"strconv"
	"strings"

	"hunter.local/assistant/mcp/internal/codec"
	"hunter.local/assistant/mcp/internal/readmodule"
	"hunter.local/assistant/mcp/internal/tool"
)

var newRejected = errors.New("tool response rejected")

func newCVEsTool(filterFields []readmodule.ListField) tool.Tool {
	fields := append([]readmodule.ListField{
		{Name: "since", Kind: "string", MaxLen: 40}, {Name: "since_id", Kind: "string", MaxLen: 255},
		{Name: "limit", Kind: "int", Min: 1, Max: 50},
	}, filterFields...)
	properties := make(map[string]any, len(fields))
	for _, field := range fields {
		definition := map[string]any{"type": "string"}
		if field.Kind == "int" {
			definition = map[string]any{"type": "integer", "minimum": field.Min, "maximum": field.Max}
		} else {
			definition["maxLength"] = field.MaxLen
		}
		properties[field.Name] = definition
	}
	schema, _ := json.Marshal(map[string]any{"type": "object", "additionalProperties": false, "properties": properties})
	return tool.Tool{
		Name: "list_new_cves", Scope: "cves_read",
		Description: "List newly first-seen CVEs from a bounded cursor.",
		InputSchema: schema, OutputSchema: tool.ResultSchema,
		Decode: decodeNew(fields), BuildRequest: buildNew, Validate: validateNew,
	}
}

func decodeNew(fields []readmodule.ListField) func([]byte) (tool.Request, error) {
	allowed := make(map[string]readmodule.ListField, len(fields))
	for _, field := range fields {
		allowed[field.Name] = field
	}
	return func(args []byte) (tool.Request, error) {
		var values map[string]json.RawMessage
		if codec.DecodeClosed(args, &values) != nil {
			return tool.Request{}, codec.ErrInvalid
		}
		for name, raw := range values {
			field, ok := allowed[name]
			if !ok {
				return tool.Request{}, codec.ErrInvalid
			}
			if field.Kind == "int" {
				var value int
				if json.Unmarshal(raw, &value) != nil || value < field.Min || value > field.Max {
					return tool.Request{}, codec.ErrInvalid
				}
			} else {
				var value string
				if json.Unmarshal(raw, &value) != nil || len(value) > field.MaxLen {
					return tool.Request{}, codec.ErrInvalid
				}
			}
		}
		return tool.Request{Payload: values}, nil
	}
}

func buildNew(request tool.Request) (tool.Call, error) {
	values := url.Values{}
	for name, raw := range request.Payload.(map[string]json.RawMessage) {
		var text string
		if json.Unmarshal(raw, &text) != nil {
			var number int
			_ = json.Unmarshal(raw, &number)
			text = strconv.Itoa(number)
		}
		values.Set(name, text)
	}
	path := "/api/v1/assistant/machine/cves/new"
	if query := values.Encode(); query != "" {
		path += "?" + query
	}
	return tool.Call{Method: "GET", Path: path}, nil
}

func validateNew(payload []byte) error {
	var root map[string]json.RawMessage
	if codec.DecodeRawClosed(payload, &root) != nil || !codec.ExactKeys(root,
		[]string{"correlation_id", "count", "limit", "items", "next_since", "next_since_id"}) {
		return newRejected
	}
	var correlation string
	var count, limit int
	var items []map[string]json.RawMessage
	if json.Unmarshal(root["correlation_id"], &correlation) != nil || !readmodule.UUIDPattern.MatchString(correlation) ||
		json.Unmarshal(root["count"], &count) != nil || count < 0 ||
		json.Unmarshal(root["limit"], &limit) != nil || limit < 1 || limit > 50 ||
		json.Unmarshal(root["items"], &items) != nil || len(items) != count || len(items) > limit {
		return newRejected
	}
	for _, item := range items {
		if !codec.ExactKeys(item, []string{"id", "summary", "severity_level", "severity_score", "has_fix", "modified"}) {
			return newRejected
		}
	}
	for _, key := range []string{"next_since", "next_since_id"} {
		if string(root[key]) == "null" {
			continue
		}
		var value string
		if json.Unmarshal(root[key], &value) != nil || len(value) > 255 || strings.ContainsAny(value, "\r\n") {
			return newRejected
		}
	}
	return nil
}
