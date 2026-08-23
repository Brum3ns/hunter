package runner

import (
	"testing"

	"hunter.local/assistant/mcp/internal/modules/targets"
	"hunter.local/assistant/mcp/internal/tool"
)

type mod struct{ names []string }

func (m mod) Tools() []tool.Tool {
	out := make([]tool.Tool, len(m.names))
	for i, n := range m.names {
		out[i] = tool.Tool{Name: n}
	}
	return out
}

func TestRegistrySortsAndLooksUp(t *testing.T) {
	r := NewRegistry()
	r.Add(mod{names: []string{"b_tool", "a_tool"}})
	if got := r.Names(); got[0] != "a_tool" || got[1] != "b_tool" {
		t.Fatalf("not sorted: %v", got)
	}
	if _, ok := r.Lookup("a_tool"); !ok {
		t.Fatal("lookup failed")
	}
	if _, ok := r.Lookup("missing"); ok {
		t.Fatal("unexpected hit")
	}
	if names := r.Tools(); len(names) != 2 || names[0].Name != "a_tool" {
		t.Fatalf("Tools() not sorted: %+v", names)
	}
}

func TestRegistryPanicsOnDuplicate(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("expected panic on duplicate")
		}
	}()
	NewRegistry().Add(mod{names: []string{"x", "x"}})
}

func TestReviewedRegistryAppliesGeneratedAuthorityMetadata(t *testing.T) {
	r := NewRegistry()
	r.AddReviewed(targets.Module{})
	definition, ok := r.Lookup("list_targets")
	if !ok {
		t.Fatal("list_targets missing")
	}
	if definition.Module != "targets" || definition.Effect != "read" ||
		definition.Scope != "targets_read" || definition.MachineMethod != "GET" ||
		definition.MachinePath != "/api/v1/assistant/machine/targets" ||
		definition.InputSchemaVersion != 1 || definition.OutputSchemaVersion != 1 {
		t.Fatalf("reviewed metadata not applied: %+v", definition)
	}
	if err := r.RequireReviewedCatalog(); err == nil {
		t.Fatal("incomplete reviewed catalog accepted")
	}
}

func TestReviewedRegistryRejectsUnknownLegacyOrInjectedTools(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("unknown reviewed tool accepted")
		}
	}()
	NewRegistry().AddReviewed(mod{names: []string{"request"}})
}
