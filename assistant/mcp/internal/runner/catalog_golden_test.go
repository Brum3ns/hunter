package runner

import (
	"encoding/json"
	"os"
	"testing"

	artifacts "hunter.local/assistant/mcp/internal/modules/artifacts"
	contextmod "hunter.local/assistant/mcp/internal/modules/context"
	policies "hunter.local/assistant/mcp/internal/modules/policies"
	validation "hunter.local/assistant/mcp/internal/modules/validation"
)

type goldenTool struct {
	Name         string          `json:"name"`
	Description  string          `json:"description"`
	InputSchema  json.RawMessage `json:"input_schema"`
	OutputSchema json.RawMessage `json:"output_schema"`
}

func normalizeSchema(t *testing.T, raw json.RawMessage) string {
	t.Helper()
	var v any
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatalf("bad schema JSON: %v", err)
	}
	out, _ := json.Marshal(v)
	return string(out)
}

// TestCatalogMatchesGolden proves the migrated modules advertise byte-identical
// (semantically normalized) tool definitions to the pre-refactor catalog.
func TestCatalogMatchesGolden(t *testing.T) {
	reg := NewRegistry()
	reg.Add(contextmod.Module{}, artifacts.Module{}, policies.Module{}, validation.Module{})

	raw, err := os.ReadFile("testdata/catalog_golden.json")
	if err != nil {
		t.Fatalf("read golden: %v", err)
	}
	var golden []goldenTool
	if err := json.Unmarshal(raw, &golden); err != nil {
		t.Fatalf("parse golden: %v", err)
	}
	want := map[string]goldenTool{}
	for _, g := range golden {
		want[g.Name] = g
	}

	got := reg.Tools()
	if len(got) != len(want) {
		t.Fatalf("tool count: got %d want %d", len(got), len(want))
	}
	for _, tl := range got {
		g, ok := want[tl.Name]
		if !ok {
			t.Fatalf("unexpected tool %s", tl.Name)
		}
		if tl.Description != g.Description {
			t.Errorf("%s description drift: %q vs %q", tl.Name, tl.Description, g.Description)
		}
		if normalizeSchema(t, tl.InputSchema) != normalizeSchema(t, g.InputSchema) {
			t.Errorf("%s input schema drift", tl.Name)
		}
		if normalizeSchema(t, tl.OutputSchema) != normalizeSchema(t, g.OutputSchema) {
			t.Errorf("%s output schema drift", tl.Name)
		}
	}
}
