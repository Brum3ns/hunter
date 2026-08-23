// Package capabilities exposes the Assistant's live, narrowed Hunter
// capability catalog. It has no mutation path.
package capabilities

import (
	"encoding/json"
	"errors"
	"regexp"

	"hunter.local/assistant/mcp/internal/codec"
	"hunter.local/assistant/mcp/internal/readmodule"
	"hunter.local/assistant/mcp/internal/tool"
)

type Module struct{}

var (
	errRejected    = errors.New("tool response rejected")
	safeSlug       = regexp.MustCompile(`^[a-z][a-z0-9_]*$`)
	inputSchema    = json.RawMessage(`{"type":"object","additionalProperties":false,"properties":{}}`)
	capabilityKeys = []string{"name", "module", "effect", "scope", "gate", "rate_profile", "idempotency"}
	limitKeys      = []string{
		"calls_per_turn", "calls_hard_ceiling", "result_bytes_per_call", "result_bytes_per_turn",
		"effects_per_turn", "effects_per_hour", "launches_per_turn", "launches_per_hour",
	}
)

func (Module) Tools() []tool.Tool {
	return []tool.Tool{{
		Name:        "list_hunter_capabilities",
		Description: "List the exact Hunter MCP capabilities currently enabled for this Assistant turn, with safe authority metadata and effective workflow limits.",
		InputSchema: inputSchema, OutputSchema: tool.ResultSchema,
		Scope:  "hunter_capabilities_read",
		Decode: decode, BuildRequest: build, Validate: validate,
	}}
}

func decode(args []byte) (tool.Request, error) {
	var input struct{}
	if err := codec.DecodeClosed(args, &input); err != nil {
		return tool.Request{}, codec.ErrInvalid
	}
	return tool.Request{}, nil
}

func build(tool.Request) (tool.Call, error) {
	return tool.Call{Method: "GET", Path: "/api/v1/assistant/machine/capabilities"}, nil
}

func validate(payload []byte) error {
	var root map[string]json.RawMessage
	if codec.DecodeRawClosed(payload, &root) != nil ||
		!codec.ExactKeys(root, []string{"correlation_id", "catalog_version", "limits", "tools"}) {
		return errRejected
	}
	var correlationID string
	var version int
	if json.Unmarshal(root["correlation_id"], &correlationID) != nil ||
		!readmodule.UUIDPattern.MatchString(correlationID) ||
		json.Unmarshal(root["catalog_version"], &version) != nil || version != 1 {
		return errRejected
	}

	var limits map[string]json.RawMessage
	if codec.DecodeRawClosed(root["limits"], &limits) != nil || !codec.ExactKeys(limits, limitKeys) {
		return errRejected
	}
	values := make(map[string]int, len(limits))
	for name, raw := range limits {
		var value int
		if json.Unmarshal(raw, &value) != nil || value <= 0 {
			return errRejected
		}
		values[name] = value
	}
	if values["calls_per_turn"] > values["calls_hard_ceiling"] || values["calls_hard_ceiling"] > 128 ||
		values["result_bytes_per_call"] > 1<<20 || values["result_bytes_per_turn"] > 16<<20 ||
		values["effects_per_turn"] > 64 || values["effects_per_hour"] > 240 ||
		values["launches_per_turn"] > 32 || values["launches_per_hour"] > 120 {
		return errRejected
	}

	var entries []map[string]json.RawMessage
	if json.Unmarshal(root["tools"], &entries) != nil || len(entries) > 70 {
		return errRejected
	}
	seen := make(map[string]struct{}, len(entries))
	for _, entry := range entries {
		if !codec.ExactKeys(entry, capabilityKeys) {
			return errRejected
		}
		values := make(map[string]string, len(entry))
		for name, raw := range entry {
			var value string
			if json.Unmarshal(raw, &value) != nil || !safeSlug.MatchString(value) {
				return errRejected
			}
			values[name] = value
		}
		if _, duplicate := seen[values["name"]]; duplicate {
			return errRejected
		}
		seen[values["name"]] = struct{}{}
	}
	return nil
}
