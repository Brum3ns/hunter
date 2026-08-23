package runner

import (
	"encoding/json"
	"os"
	"slices"
	"strings"
	"testing"

	"hunter.local/assistant/mcp/internal/catalog"
	capabilities "hunter.local/assistant/mcp/internal/modules/capabilities"
	ccJobs "hunter.local/assistant/mcp/internal/modules/cc_jobs"
	ccPlaybooks "hunter.local/assistant/mcp/internal/modules/cc_playbooks"
	ccRunEvents "hunter.local/assistant/mcp/internal/modules/cc_run_events"
	ccRunGroups "hunter.local/assistant/mcp/internal/modules/cc_run_groups"
	ccRuns "hunter.local/assistant/mcp/internal/modules/cc_runs"
	ccTemplates "hunter.local/assistant/mcp/internal/modules/cc_templates"
	ccwrite "hunter.local/assistant/mcp/internal/modules/ccwrite"
	cves "hunter.local/assistant/mcp/internal/modules/cves"
	operational "hunter.local/assistant/mcp/internal/modules/operational"
	programs "hunter.local/assistant/mcp/internal/modules/programs"
	sitemap "hunter.local/assistant/mcp/internal/modules/sitemap"
	targets "hunter.local/assistant/mcp/internal/modules/targets"
	vulnerabilities "hunter.local/assistant/mcp/internal/modules/vulnerabilities"
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

// TestCatalogMatchesGolden proves every reviewed capability has one stable MCP
// tool schema and no module can advertise authority outside the checked catalog.
func TestCatalogMatchesGolden(t *testing.T) {
	reg := NewRegistry()
	reg.AddReviewed(
		capabilities.Module{}, targets.Module{},
		cves.Module{}, vulnerabilities.Module{}, sitemap.Module{}, programs.Module{},
		ccTemplates.Module{}, ccJobs.Module{}, ccPlaybooks.Module{}, ccRunGroups.Module{}, ccRuns.Module{}, ccRunEvents.Module{},
		ccwrite.Module{}, operational.Module{},
	)
	if err := reg.RequireReviewedCatalog(); err != nil {
		t.Fatal(err)
	}
	if os.Getenv("UPDATE_GOLDEN") == "1" {
		generated := make([]goldenTool, 0, len(reg.Tools()))
		for _, tl := range reg.Tools() {
			generated = append(generated, goldenTool{
				Name: tl.Name, Description: tl.Description,
				InputSchema: tl.InputSchema, OutputSchema: tl.OutputSchema,
			})
		}
		encoded, err := json.MarshalIndent(generated, "", "  ")
		if err != nil {
			t.Fatalf("marshal golden: %v", err)
		}
		encoded = append(encoded, '\n')
		if err := os.WriteFile("testdata/catalog_golden.json", encoded, 0o644); err != nil {
			t.Fatalf("write golden: %v", err)
		}
	}

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
	gotNames := make([]string, 0, len(got))
	for _, tl := range got {
		gotNames = append(gotNames, tl.Name)
		definition, exists := catalog.Lookup(tl.Name)
		if !exists {
			t.Fatalf("tool absent from authority catalog: %s", tl.Name)
		}
		wantWrite := !slices.Contains([]string{"read", "analyze", "validate"}, definition.Effect)
		if tl.WriteScope != wantWrite {
			t.Fatalf("unreviewed write authority on %s", tl.Name)
		}
		for _, prefix := range []string{"delete_", "destroy_", "purge_", "request_", "shell_", "filesystem_"} {
			if strings.HasPrefix(tl.Name, prefix) {
				t.Fatalf("prohibited effectful tool %s", tl.Name)
			}
		}
	}
	if !slices.Equal(gotNames, catalog.Names()) {
		t.Fatalf("catalog authority drift: got %#v want %#v", gotNames, catalog.Names())
	}
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
