package runner

import (
	"fmt"
	"slices"

	"hunter.local/assistant/mcp/internal/catalog"
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
			r.add(t)
		}
	}
}

// AddReviewed registers only tools present in the checked capability catalog
// and copies authority metadata from that catalog. Module code continues to
// own schemas, decoding, request construction, and response validation.
func (r *Registry) AddReviewed(modules ...tool.Module) {
	for _, module := range modules {
		for _, candidate := range module.Tools() {
			definition, ok := catalog.Lookup(candidate.Name)
			if !ok {
				panic(fmt.Sprintf("tool is absent from reviewed catalog: %s", candidate.Name))
			}
			candidate.Module = definition.Module
			candidate.Effect = definition.Effect
			candidate.Scope = definition.Scope
			candidate.WriteScope = definition.Effect != "read" && definition.Effect != "analyze" && definition.Effect != "validate"
			candidate.Gate = definition.Gate
			candidate.RateProfile = definition.RateProfile
			candidate.ByteProfile = definition.ByteProfile
			candidate.Idempotency = definition.Idempotency
			candidate.MachineMethod = definition.Method
			candidate.MachinePath = definition.Path
			candidate.InputSchemaVersion = definition.InputSchemaVersion
			candidate.OutputSchemaVersion = definition.OutputSchemaVersion
			r.add(candidate)
		}
	}
}

func (r *Registry) RequireReviewedCatalog() error {
	if !slices.Equal(r.Names(), catalog.Names()) {
		return fmt.Errorf("registered tools do not match reviewed catalog")
	}
	return nil
}

func (r *Registry) add(t tool.Tool) {
	if _, exists := r.tools[t.Name]; exists {
		panic(fmt.Sprintf("duplicate tool: %s", t.Name))
	}
	r.tools[t.Name] = t
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
