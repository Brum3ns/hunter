package runner

import (
	"testing"

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
