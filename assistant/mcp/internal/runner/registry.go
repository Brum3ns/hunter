package runner

import (
	"fmt"
	"slices"

	"hunter.local/assistant/mcp/internal/tool"
)

// Registry holds every advertised tool, keyed by name, contributed by modules.
type Registry struct {
	tools map[string]tool.Tool
}

func NewRegistry() *Registry { return &Registry{tools: map[string]tool.Tool{}} }

// Add registers each module's tools; it panics on a duplicate tool name so a
// wiring mistake fails loudly at startup rather than shadowing silently.
func (r *Registry) Add(modules ...tool.Module) {
	for _, module := range modules {
		for _, t := range module.Tools() {
			if _, exists := r.tools[t.Name]; exists {
				panic(fmt.Sprintf("duplicate tool: %s", t.Name))
			}
			r.tools[t.Name] = t
		}
	}
}

func (r *Registry) Lookup(name string) (tool.Tool, bool) {
	t, ok := r.tools[name]
	return t, ok
}

func (r *Registry) Names() []string {
	names := make([]string, 0, len(r.tools))
	for name := range r.tools {
		names = append(names, name)
	}
	slices.Sort(names)
	return names
}

func (r *Registry) Tools() []tool.Tool {
	out := make([]tool.Tool, 0, len(r.tools))
	for _, name := range r.Names() {
		out = append(out, r.tools[name])
	}
	return out
}
