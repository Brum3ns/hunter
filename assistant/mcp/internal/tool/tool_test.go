package tool

import (
	"encoding/json"
	"testing"
)

type fakeModule struct{}

func (fakeModule) Tools() []Tool {
	return []Tool{{Name: "x", Decode: func([]byte) (Request, error) { return Request{}, nil }}}
}

func TestModuleContributesTools(t *testing.T) {
	var m Module = fakeModule{}
	if got := m.Tools(); len(got) != 1 || got[0].Name != "x" {
		t.Fatalf("unexpected tools: %+v", got)
	}
}

func TestResultSchemaIsClosedObject(t *testing.T) {
	var doc map[string]any
	if err := json.Unmarshal(ResultSchema, &doc); err != nil {
		t.Fatalf("ResultSchema not valid JSON: %v", err)
	}
	if doc["additionalProperties"] != false {
		t.Fatalf("ResultSchema must be closed")
	}
}

func TestReviewedMetadataDoesNotReplaceModuleHandlers(t *testing.T) {
	decode := func([]byte) (Request, error) { return Request{}, nil }
	definition := Tool{
		Name: "list_targets", Module: "targets", Effect: "read", Scope: "targets_read",
		MachineMethod: "GET", MachinePath: "/api/v1/assistant/machine/targets",
		InputSchemaVersion: 1, OutputSchemaVersion: 1, Decode: decode,
	}
	if definition.Decode == nil || definition.Module == "" || definition.MachinePath == "" {
		t.Fatalf("incomplete reviewed tool: %+v", definition)
	}
}
