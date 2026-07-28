// Package readmodule builds a dedicated, per-module read-only list_*/get_* tool
// pair from a declarative Spec, preserving closed input schemas, closed output
// validation, exact-key projection allowlists and a safe-id pattern. It is a
// compile-time helper — every tool it emits is independently named and scoped.
package readmodule

import "regexp"

// ListField is one closed query parameter a list_* tool accepts.
type ListField struct {
	Name   string // JSON/query key
	Kind   string // "string" or "int"
	MaxLen int    // string only; 0 ⇒ unbounded (schema still closed)
	Min    int    // int only
	Max    int    // int only
}

// Spec fully describes one module's read tool pair.
type Spec struct {
	ListTool  string
	GetTool   string
	Scope     string
	BasePath  string // "/api/v1/assistant/machine/<segment>"
	DetailKey string // envelope key for get_* ("cve", "target", ...)
	ListDesc  string
	GetDesc   string

	ListFields  []ListField // extra filters; page+limit are always added
	SummaryKeys []string    // exact keys of each list item
	FullKeys    []string    // exact keys of the detail object

	IDPattern *regexp.Regexp // nil ⇒ codec.SafeID
	MaxItems  int            // 0 ⇒ 50
}

// UUIDPattern is the correlation-id shape every read envelope must carry.
var UUIDPattern = regexp.MustCompile(
	`^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)

func (s Spec) maxItems() int {
	if s.MaxItems > 0 {
		return s.MaxItems
	}
	return 50
}
