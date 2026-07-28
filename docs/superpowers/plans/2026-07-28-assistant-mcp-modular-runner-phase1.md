# Assistant MCP Modular Runner — Phase 1 (Reorganization) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure the `assistant/mcp` Go service so each Hunter-API surface is its own internal package, all cross-cutting security logic lives once in a `runner`, and the existing six tools are migrated 1:1 with zero behavior change.

**Architecture:** Introduce four shared packages (`tool` contracts, `codec` closed-JSON helpers, `resource` shared resource-ref decode, `transport` generic authenticated HTTP) and a `runner` (registry + one dispatch pipeline + MCP wiring). Each tool becomes a self-describing `tool.Tool` value contributed by a per-endpoint `modules/*` package; the runner drives them generically with no per-tool `switch`. The monolithic `internal/tools` and the tool→path `routes` map in `internal/hunter` are deleted.

**Tech Stack:** Go 1.25.12, `github.com/modelcontextprotocol/go-sdk` v1.6.0, standard library only. No new dependencies.

## Global Constraints

- Go module floor is `go 1.25.12` (`assistant/mcp/go.mod`); do not raise it, add no new `require`.
- The MCP reaches Hunter **only** through `/api/v1/assistant/machine/*`; every request sends `Authorization: Bearer <service token>` and `X-Hunter-Turn-Grant: <grant>`, `Accept: application/json`.
- All tool input is **closed**: reject empty, `> 64<<10` bytes, invalid UTF-8, unknown fields, or trailing data.
- Closed output validation and redaction run on every payload before return.
- Per-grant budget cap is `limits.NewBudget(8)` (≤8 calls/turn); do not change it.
- The **advertised catalog** (each tool's Name, Description, InputSchema, OutputSchema) MUST be semantically identical before and after this phase — proven by a golden test (Task 12).
- Verify every task from `assistant/mcp/`: `go test ./...` (and `go build ./...` where noted). Commit author `Claude <noreply@anthropic.com>`, one-sentence messages.

---

### Task 1: `internal/tool` contracts package

**Files:**
- Create: `assistant/mcp/internal/tool/tool.go`
- Test: `assistant/mcp/internal/tool/tool_test.go`

**Interfaces:**
- Produces: `tool.Resource{Type,ID string}`; `tool.Call{Method,Path string; Body []byte}`; `tool.Request{Payload any; Resource *Resource}`; `tool.Tool{Name,Description string; InputSchema,OutputSchema json.RawMessage; Scope string; RequiresResource bool; Decode func([]byte)(Request,error); BuildRequest func(Request)(Call,error); Validate func([]byte) error}`; `tool.Module interface{ Tools() []Tool }`; `tool.ResultSchema json.RawMessage`.

- [ ] **Step 1: Write the failing test**

```go
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd assistant/mcp && go test ./internal/tool/`
Expected: FAIL (package/types not defined).

- [ ] **Step 3: Write minimal implementation**

```go
// Package tool holds the dependency-free contracts every MCP module and the
// runner share. It imports nothing from the rest of the service.
package tool

import "encoding/json"

// Resource is an explicit {type,id} pair a turn grant may authorize.
type Resource struct {
	Type string `json:"type"`
	ID   string `json:"id"`
}

// Call is a machine-namespace request a module produces; the transport runs it.
type Call struct {
	Method string
	Path   string
	Body   []byte // nil for GET
}

// Request is a decoded, validated tool input plus the optional resource it targets.
type Request struct {
	Payload  any
	Resource *Resource
}

// Tool is a fully self-describing MCP tool the runner drives generically.
type Tool struct {
	Name             string
	Description      string
	InputSchema      json.RawMessage
	OutputSchema     json.RawMessage
	Scope            string // read scope required (Phase 2); "" = no scope gate
	RequiresResource bool   // true iff an explicit resource grant is required

	Decode       func(args []byte) (Request, error)
	BuildRequest func(req Request) (Call, error)
	Validate     func(payload []byte) error
}

// Module contributes a set of tools to the registry.
type Module interface {
	Tools() []Tool
}

// ResultSchema is the shared output envelope every tool advertises: {result:object}.
var ResultSchema = json.RawMessage(`{
    "type":"object","additionalProperties":false,"required":["result"],
    "properties":{"result":{"type":"object"}}
  }`)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd assistant/mcp && go test ./internal/tool/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add assistant/mcp/internal/tool/
git commit -m "Add the dependency-free tool contracts package for the MCP runner."
```

---

### Task 2: `internal/codec` closed-JSON helpers

**Files:**
- Create: `assistant/mcp/internal/codec/codec.go`
- Test: `assistant/mcp/internal/codec/codec_test.go`

**Interfaces:**
- Produces: `codec.MaxInputBytes = 64 << 10`; `codec.SafeID *regexp.Regexp`; `codec.ErrInvalid error`; `codec.DecodeClosed(input []byte, dst any) error`; `codec.DecodeRawClosed(raw json.RawMessage, dst any) error`; `codec.ExactKeys(fields map[string]json.RawMessage, required []string) bool`.
- Note: `DecodeClosed` is moved verbatim from `internal/tools/handlers.go:212-225`; `DecodeRawClosed` from `handlers.go:386-399` (return `ErrInvalid` in place of the old `ErrInvalidInput`/`ErrResponseRejected`); `ExactKeys` from `handlers.go:374-384`; `SafeID` is the `safeID` regexp from `handlers.go:30`.

- [ ] **Step 1: Write the failing test**

```go
package codec

import "testing"

type sample struct {
	A string `json:"a"`
}

func TestDecodeClosedRejects(t *testing.T) {
	cases := map[string]string{
		"empty":        ``,
		"unknownField": `{"a":"x","b":1}`,
		"trailing":     `{"a":"x"}{}`,
		"notObject":    `[]`,
	}
	for name, in := range cases {
		var dst sample
		if err := DecodeClosed([]byte(in), &dst); err == nil {
			t.Errorf("%s: expected error", name)
		}
	}
	var dst sample
	if err := DecodeClosed([]byte(`{"a":"x"}`), &dst); err != nil || dst.A != "x" {
		t.Fatalf("valid input rejected: %v", err)
	}
}

func TestExactKeys(t *testing.T) {
	f := map[string][]byte{"a": nil, "b": nil}
	// convert to json.RawMessage map
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd assistant/mcp && go test ./internal/codec/`
Expected: FAIL (package not defined).

- [ ] **Step 3: Write minimal implementation**

```go
// Package codec holds the closed-JSON decode helpers shared by every module.
package codec

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"regexp"
	"unicode/utf8"
)

const MaxInputBytes = 64 << 10

// SafeID bounds every resource/id string a tool accepts or a grant authorizes.
var SafeID = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:-]{0,254}$`)

var ErrInvalid = errors.New("invalid closed input")

// DecodeClosed strictly decodes a single JSON object with no unknown or trailing data.
func DecodeClosed(input []byte, destination any) error {
	if len(input) == 0 || len(input) > MaxInputBytes || !utf8.Valid(input) {
		return ErrInvalid
	}
	decoder := json.NewDecoder(bytes.NewReader(input))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(destination); err != nil {
		return ErrInvalid
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return ErrInvalid
	}
	return nil
}

// DecodeRawClosed is DecodeClosed for an already-extracted json.RawMessage.
func DecodeRawClosed(input json.RawMessage, destination any) error {
	if !utf8.Valid(input) {
		return ErrInvalid
	}
	decoder := json.NewDecoder(bytes.NewReader(input))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(destination); err != nil {
		return err
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return ErrInvalid
	}
	return nil
}

// ExactKeys reports whether fields has exactly the required keys, no more, no fewer.
func ExactKeys(fields map[string]json.RawMessage, required []string) bool {
	if len(fields) != len(required) {
		return false
	}
	for _, key := range required {
		if _, ok := fields[key]; !ok {
			return false
		}
	}
	return true
}
```

- [ ] **Step 4: Complete and run the tests**

Finish `TestExactKeys` with a real `map[string]json.RawMessage` asserting `ExactKeys` true for exact match and false for missing/extra.
Run: `cd assistant/mcp && go test ./internal/codec/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add assistant/mcp/internal/codec/
git commit -m "Add the shared closed-JSON codec helpers for the MCP modules."
```

---

### Task 3: `internal/resource` shared resource-ref decode

**Files:**
- Create: `assistant/mcp/internal/resource/resource.go`
- Test: `assistant/mcp/internal/resource/resource_test.go`

**Interfaces:**
- Consumes: `codec.DecodeClosed`, `codec.SafeID`; `tool.Resource`.
- Produces: `resource.Types []string` (the six-type list from `handlers.go:36-38`); `resource.Input{Type,ID string}`; `resource.Decode(args []byte) (Input, error)` (mirrors `DecodeExactResource`, `handlers.go:113-119`); `resource.Schema json.RawMessage` (the `resourceSchema` from `catalog.go:23-31`).

- [ ] **Step 1: Write the failing test**

```go
package resource

import "testing"

func TestDecodeAcceptsGrantedTypes(t *testing.T) {
	in, err := Decode([]byte(`{"type":"target","id":"host-1"}`))
	if err != nil || in.Type != "target" || in.ID != "host-1" {
		t.Fatalf("valid resource rejected: %v", err)
	}
}

func TestDecodeRejects(t *testing.T) {
	for _, in := range []string{
		`{"type":"bogus","id":"x"}`,
		`{"type":"target","id":"bad id"}`,
		`{"type":"target"}`,
		`{"type":"target","id":"x","extra":1}`,
	} {
		if _, err := Decode([]byte(in)); err == nil {
			t.Errorf("expected rejection for %s", in)
		}
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd assistant/mcp && go test ./internal/resource/`
Expected: FAIL (package not defined).

- [ ] **Step 3: Write minimal implementation**

```go
// Package resource decodes the {type,id} reference shared by resource-bound tools.
package resource

import (
	"encoding/json"
	"slices"

	"hunter.local/assistant/mcp/internal/codec"
)

// Types is the closed set of resource kinds a grant may reference.
var Types = []string{
	"program", "target", "cve", "vulnerability", "whiterabbit_template", "ansible_playbook",
}

// Schema is the advertised input schema for resource-bound tools.
var Schema = json.RawMessage(`{
    "type":"object",
    "additionalProperties":false,
    "required":["type","id"],
    "properties":{
      "type":{"type":"string","enum":["program","target","cve","vulnerability","whiterabbit_template","ansible_playbook"]},
      "id":{"type":"string","minLength":1,"maxLength":255,"pattern":"^[A-Za-z0-9][A-Za-z0-9._:-]*$"}
    }
  }`)

type Input struct {
	Type string `json:"type"`
	ID   string `json:"id"`
}

// Decode strictly parses a resource reference, enforcing the type enum and id shape.
func Decode(args []byte) (Input, error) {
	var in Input
	if err := codec.DecodeClosed(args, &in); err != nil || !slices.Contains(Types, in.Type) || !codec.SafeID.MatchString(in.ID) {
		return Input{}, codec.ErrInvalid
	}
	return in, nil
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd assistant/mcp && go test ./internal/resource/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add assistant/mcp/internal/resource/
git commit -m "Add the shared resource-reference decoder for resource-bound MCP tools."
```

---

### Task 4: `internal/transport` generic authenticated client

**Files:**
- Create: `assistant/mcp/internal/transport/transport.go`
- Test: `assistant/mcp/internal/transport/transport_test.go`

**Interfaces:**
- Consumes: `tool.Resource`.
- Produces: `transport.Grant{GrantID int64; CorrelationID string; Tools []string; Resources []tool.Resource; ExpiresAt time.Time; CallsRemaining int; BytesRemaining int; ReadScopes []string}`; `transport.Client`; `transport.NewClient(baseURL, serviceToken string, timeout time.Duration, maxResponseBytes int64) (*Client, error)`; `(*Client).Introspect(ctx, grant string) (Grant, error)`; `(*Client).Do(ctx context.Context, method, path, grant string, body []byte) ([]byte, error)`; error vars `ErrUnexpectedResponse`, `ErrResponseTooLarge`.
- Migration: port `internal/hunter/client.go` — keep `NewHTTPClient`'s URL validation (`client.go:53-73`) as `NewClient` **minus** the `routes` map; keep `Introspect` (`client.go:91-103`) verbatim; export the private `request` method (`client.go:133-172`) as `Do(ctx, method, path, grant, body)`. Add `ReadScopes []string json:"read_scopes"` to `Grant` (Rails omits it today; `DisallowUnknownFields` tolerates an absent field, so it decodes to nil).

- [ ] **Step 1: Write the failing test**

```go
package transport

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func newTestClient(t *testing.T, url string) *Client {
	c, err := NewClient(url, "svc-token", 2*time.Second, 64<<10)
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	return c
}

func TestDoSendsServiceAndGrantHeaders(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer svc-token" || r.Header.Get("X-Hunter-Turn-Grant") != "g1" {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"ok":true}`))
	}))
	defer server.Close()

	body, err := newTestClient(t, server.URL).Do(context.Background(), http.MethodGet, "/api/v1/assistant/machine/x", "g1", nil)
	if err != nil || string(body) != `{"ok":true}` {
		t.Fatalf("Do: %q err=%v", body, err)
	}
}

func TestIntrospectRejectsUnknownFields(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"grant_id":1,"surprise":2}`))
	}))
	defer server.Close()
	if _, err := newTestClient(t, server.URL).Introspect(context.Background(), "g1"); err == nil {
		t.Fatal("expected unknown-field rejection")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd assistant/mcp && go test ./internal/transport/`
Expected: FAIL (package not defined).

- [ ] **Step 3: Write minimal implementation**

Port `internal/hunter/client.go` into `transport.go` as described in the migration note above: `NewClient` (URL guards, no `routes`), `Introspect`, and the exported `Do`. Use this `Grant` type:

```go
type Grant struct {
	GrantID        int64           `json:"grant_id"`
	CorrelationID  string          `json:"correlation_id"`
	Tools          []string        `json:"tools"`
	Resources      []tool.Resource `json:"resources"`
	ExpiresAt      time.Time       `json:"expires_at"`
	CallsRemaining int             `json:"calls_remaining"`
	BytesRemaining int             `json:"bytes_remaining"`
	ReadScopes     []string        `json:"read_scopes"`
}
```

`Do` is the old `request` method with signature `Do(ctx context.Context, method, path, grant string, body []byte) ([]byte, error)` (the header-setting, redirect refusal, status/content-type checks, and `maxResponseBytes` cap are unchanged).

- [ ] **Step 4: Run test to verify it passes**

Run: `cd assistant/mcp && go test ./internal/transport/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add assistant/mcp/internal/transport/
git commit -m "Add the generic machine-namespace transport, replacing the tool-to-path route map."
```

---

### Task 5: `internal/runner` registry + backend interface

**Files:**
- Create: `assistant/mcp/internal/runner/registry.go`
- Create: `assistant/mcp/internal/runner/backend.go`
- Test: `assistant/mcp/internal/runner/registry_test.go`

**Interfaces:**
- Consumes: `tool.Module`, `tool.Tool`, `transport.Grant`.
- Produces: `runner.Backend interface{ Introspect(context.Context,string)(transport.Grant,error); Do(context.Context,string,string,string,[]byte)([]byte,error) }`; `runner.Registry`; `runner.NewRegistry() *Registry`; `(*Registry).Add(modules ...tool.Module)` (panics on duplicate tool name); `(*Registry).Lookup(name string) (tool.Tool, bool)`; `(*Registry).Tools() []tool.Tool` (sorted by name); `(*Registry).Names() []string` (sorted).

- [ ] **Step 1: Write the failing test**

```go
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
}

func TestRegistryPanicsOnDuplicate(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("expected panic on duplicate")
		}
	}()
	NewRegistry().Add(mod{names: []string{"x", "x"}})
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd assistant/mcp && go test ./internal/runner/`
Expected: FAIL (package not defined).

- [ ] **Step 3: Write minimal implementation**

```go
// backend.go
package runner

import (
	"context"

	"hunter.local/assistant/mcp/internal/transport"
)

// Backend is the subset of the transport the runner needs (fakeable in tests).
type Backend interface {
	Introspect(ctx context.Context, grant string) (transport.Grant, error)
	Do(ctx context.Context, method, path, grant string, body []byte) ([]byte, error)
}
```

```go
// registry.go
package runner

import (
	"fmt"
	"slices"

	"hunter.local/assistant/mcp/internal/tool"
)

type Registry struct {
	tools map[string]tool.Tool
}

func NewRegistry() *Registry { return &Registry{tools: map[string]tool.Tool{}} }

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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd assistant/mcp && go test ./internal/runner/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add assistant/mcp/internal/runner/registry.go assistant/mcp/internal/runner/backend.go assistant/mcp/internal/runner/registry_test.go
git commit -m "Add the MCP tool registry and backend interface."
```

---

### Task 6: `internal/runner` dispatch pipeline

**Files:**
- Create: `assistant/mcp/internal/runner/runner.go`
- Test: `assistant/mcp/internal/runner/runner_test.go`

**Interfaces:**
- Consumes: `Registry`, `Backend`, `tool.Tool`, `tool.Request`, `tool.Resource`, `transport.Grant`, `redact.Checker`, `limits.Budget`.
- Produces: error vars `ErrUnknownTool, ErrInvalidInput, ErrToolDenied, ErrResourceDenied, ErrScopeDenied, ErrGrantExpired, ErrResponseRejected`; `runner.Runner`; `runner.New(backend Backend, registry *Registry, checker *redact.Checker) *Runner`; `(*Runner).Dispatch(ctx context.Context, rawGrant, name string, args []byte) ([]byte, error)`.
- Semantics: reproduce `internal/tools/handlers.go:121-170` exactly, driven by `tool.Tool` metadata. New `ErrScopeDenied` gate: if `t.Scope != ""` and `t.Scope ∉ grant.ReadScopes` → deny (inert in Phase 1 since no migrated tool sets `Scope`).

- [ ] **Step 1: Write the failing test**

```go
package runner

import (
	"context"
	"errors"
	"testing"
	"time"

	"hunter.local/assistant/mcp/internal/redact"
	"hunter.local/assistant/mcp/internal/tool"
	"hunter.local/assistant/mcp/internal/transport"
)

type fakeBackend struct {
	grant   transport.Grant
	payload []byte
	doErr   error
}

func (f fakeBackend) Introspect(context.Context, string) (transport.Grant, error) {
	return f.grant, nil
}
func (f fakeBackend) Do(context.Context, string, string, string, []byte) ([]byte, error) {
	return f.payload, f.doErr
}

func scopedTool() tool.Module { return staticModule{t: tool.Tool{
	Name: "list_x", Scope: "targets",
	Decode:       func([]byte) (tool.Request, error) { return tool.Request{}, nil },
	BuildRequest: func(tool.Request) (tool.Call, error) { return tool.Call{Method: "GET", Path: "/p"}, nil },
	Validate:     func([]byte) error { return nil },
}}}

type staticModule struct{ t tool.Tool }
func (m staticModule) Tools() []tool.Tool { return []tool.Tool{m.t} }

func newRunner(b Backend, m tool.Module) *Runner {
	reg := NewRegistry()
	reg.Add(m)
	return New(b, reg, redact.NewChecker(64<<10))
}

func TestDispatchScopeDenied(t *testing.T) {
	b := fakeBackend{grant: transport.Grant{
		Tools: []string{"list_x"}, ReadScopes: nil,
		ExpiresAt: time.Now().Add(time.Minute), CallsRemaining: 8, BytesRemaining: 1024,
	}, payload: []byte(`{"result":1}`)}
	_, err := newRunner(b, scopedTool()).Dispatch(context.Background(), "g", "list_x", []byte(`{}`))
	if !errors.Is(err, ErrScopeDenied) {
		t.Fatalf("want ErrScopeDenied, got %v", err)
	}
}

func TestDispatchScopeGrantedHappyPath(t *testing.T) {
	b := fakeBackend{grant: transport.Grant{
		Tools: []string{"list_x"}, ReadScopes: []string{"targets"},
		ExpiresAt: time.Now().Add(time.Minute), CallsRemaining: 8, BytesRemaining: 1024,
	}, payload: []byte(`{"ok":1}`)}
	out, err := newRunner(b, scopedTool()).Dispatch(context.Background(), "g", "list_x", []byte(`{}`))
	if err != nil || string(out) != `{"ok":1}` {
		t.Fatalf("happy path failed: %q %v", out, err)
	}
}

func TestDispatchUnknownAndEmptyGrant(t *testing.T) {
	b := fakeBackend{grant: transport.Grant{ExpiresAt: time.Now().Add(time.Minute)}}
	r := newRunner(b, scopedTool())
	if _, err := r.Dispatch(context.Background(), "", "list_x", []byte(`{}`)); !errors.Is(err, ErrToolDenied) {
		t.Fatalf("empty grant: %v", err)
	}
	if _, err := r.Dispatch(context.Background(), "g", "nope", []byte(`{}`)); !errors.Is(err, ErrUnknownTool) {
		t.Fatalf("unknown tool: %v", err)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd assistant/mcp && go test ./internal/runner/ -run TestDispatch`
Expected: FAIL (Runner/New/errors not defined).

- [ ] **Step 3: Write minimal implementation**

```go
package runner

import (
	"context"
	"errors"
	"slices"
	"time"

	"hunter.local/assistant/mcp/internal/limits"
	"hunter.local/assistant/mcp/internal/redact"
)

var (
	ErrUnknownTool      = errors.New("unknown tool")
	ErrInvalidInput     = errors.New("invalid tool input")
	ErrToolDenied       = errors.New("tool not granted")
	ErrResourceDenied   = errors.New("resource not granted")
	ErrScopeDenied      = errors.New("scope not granted")
	ErrGrantExpired     = errors.New("turn grant expired")
	ErrResponseRejected = errors.New("tool response rejected")
)

type Runner struct {
	backend  Backend
	registry *Registry
	checker  *redact.Checker
	budget   *limits.Budget
}

func New(backend Backend, registry *Registry, checker *redact.Checker) *Runner {
	if checker == nil {
		checker = redact.NewChecker(64 << 10)
	}
	return &Runner{backend: backend, registry: registry, checker: checker, budget: limits.NewBudget(8)}
}

func (r *Runner) Dispatch(ctx context.Context, rawGrant, name string, args []byte) ([]byte, error) {
	if rawGrant == "" {
		return nil, ErrToolDenied
	}
	t, ok := r.registry.Lookup(name)
	if !ok {
		return nil, ErrUnknownTool
	}
	req, err := t.Decode(args)
	if err != nil {
		return nil, ErrInvalidInput
	}
	if t.RequiresResource && req.Resource == nil {
		return nil, ErrInvalidInput
	}

	grant, err := r.backend.Introspect(ctx, rawGrant)
	if err != nil {
		return nil, ErrToolDenied
	}
	if !grant.ExpiresAt.After(time.Now()) {
		return nil, ErrGrantExpired
	}
	if !slices.Contains(grant.Tools, name) {
		return nil, ErrToolDenied
	}
	if t.Scope != "" && !slices.Contains(grant.ReadScopes, t.Scope) {
		return nil, ErrScopeDenied
	}
	if req.Resource != nil && !slices.Contains(grant.Resources, *req.Resource) {
		return nil, ErrResourceDenied
	}
	if err := r.budget.Reserve(rawGrant, grant.CallsRemaining, grant.BytesRemaining); err != nil {
		return nil, ErrToolDenied
	}

	call, err := t.BuildRequest(req)
	if err != nil {
		return nil, ErrInvalidInput
	}
	payload, err := r.backend.Do(ctx, call.Method, call.Path, rawGrant, call.Body)
	if err != nil {
		if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
			return nil, err
		}
		return nil, ErrResponseRejected
	}
	if r.checker.Check(payload) != nil || t.Validate(payload) != nil {
		return nil, ErrResponseRejected
	}
	return payload, nil
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd assistant/mcp && go test ./internal/runner/`
Expected: PASS.

- [ ] **Step 5: Add branch-coverage tests, then commit**

Add tests for: expired grant → `ErrGrantExpired`; tool not in `grant.Tools` → `ErrToolDenied`; a `RequiresResource` tool whose `Decode` yields a resource not in `grant.Resources` → `ErrResourceDenied`; `Do` returning `context.Canceled` → error propagates; `Validate` returning non-nil → `ErrResponseRejected`. Then:

```bash
git add assistant/mcp/internal/runner/runner.go assistant/mcp/internal/runner/runner_test.go
git commit -m "Add the MCP runner dispatch pipeline with tool, scope, resource and budget gates."
```

---

### Task 7: `internal/runner` MCP server wiring

**Files:**
- Create: `assistant/mcp/internal/runner/register.go`
- Test: `assistant/mcp/internal/runner/register_test.go`

**Interfaces:**
- Consumes: `github.com/modelcontextprotocol/go-sdk/mcp`, `internal/auth`, `(*Runner).Dispatch`, `Registry.Tools`, `tool.ResultSchema`.
- Produces: `runner.Register(server *mcp.Server, r *Runner)`; `runner.PublicError(err error) string` (exported for tests; body from `handlers.go:401-416` plus `case errors.Is(err, ErrScopeDenied): return "scope_not_granted"`); unexported `wrapResult(payload []byte) (map[string]any, []byte, bool)`.
- Semantics: reproduce `internal/tools/catalog.go:101-129` — one `server.AddTool` per `r.registry.Tools()` entry, advertising `Name/Description/InputSchema/OutputSchema`; the handler calls `r.Dispatch(ctx, auth.GrantFromContext(ctx), name, args)`, wraps success as `{"result": <payload>}` structured content, and maps errors through `PublicError`.

- [ ] **Step 1: Write the failing test**

```go
package runner

import (
	"errors"
	"testing"
)

func TestPublicErrorMapping(t *testing.T) {
	cases := map[error]string{
		ErrUnknownTool:      "unknown_tool",
		ErrInvalidInput:     "invalid_tool_input",
		ErrResourceDenied:   "resource_not_granted",
		ErrScopeDenied:      "scope_not_granted",
		ErrToolDenied:       "turn_grant_rejected",
		ErrGrantExpired:     "turn_grant_rejected",
		ErrResponseRejected: "tool_response_rejected",
	}
	for err, want := range cases {
		if got := PublicError(err); got != want {
			t.Errorf("PublicError(%v)=%q want %q", err, got, want)
		}
	}
}

func TestWrapResultRejectsNonObject(t *testing.T) {
	if _, _, ok := wrapResult([]byte(`not json`)); ok {
		t.Fatal("expected rejection of non-object payload")
	}
	if _, _, ok := wrapResult([]byte(`{"a":1}`)); !ok {
		t.Fatal("expected object payload to wrap")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd assistant/mcp && go test ./internal/runner/ -run 'TestPublicError|TestWrapResult'`
Expected: FAIL.

- [ ] **Step 3: Write minimal implementation**

Implement `PublicError` (ported mapping, including the `context.Canceled/DeadlineExceeded` → `"tool_call_cancelled"` case), `wrapResult` (unmarshal payload to `map[string]any`; on failure return `ok=false`; else return the `{"result":…}` map and its marshaled bytes), and `Register` mirroring `catalog.go:101-129` but iterating `r.registry.Tools()` and calling `r.Dispatch`.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd assistant/mcp && go test ./internal/runner/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add assistant/mcp/internal/runner/register.go assistant/mcp/internal/runner/register_test.go
git commit -m "Wire the MCP runner to the SDK server with result wrapping and public error mapping."
```

---

### Task 8: `modules/context` — get_selected_context

**Files:**
- Create: `assistant/mcp/internal/modules/context/context.go`
- Create: `assistant/mcp/internal/modules/context/util.go`
- Test: `assistant/mcp/internal/modules/context/context_test.go`

**Interfaces:**
- Consumes: `tool`, `codec`, `resource`.
- Produces: `context.Module{}` implementing `tool.Module`; its single tool `get_selected_context`, `RequiresResource: true`, `Scope: ""`, `InputSchema: resource.Schema`, `OutputSchema: tool.ResultSchema`.
- `util.go` holds the free helper `validateKeys(payload []byte, required []string) error` (built on `codec.DecodeRawClosed`/`codec.ExactKeys`) shared conceptually with sibling modules but defined locally here (each module keeps its own copy per "functions unrelated to a struct live in the package's util.go"; the validation module has its own richer version).

- [ ] **Step 1: Write the failing test**

```go
package context

import "testing"

func TestGetSelectedContextTool(t *testing.T) {
	tools := Module{}.Tools()
	if len(tools) != 1 || tools[0].Name != "get_selected_context" || !tools[0].RequiresResource {
		t.Fatalf("unexpected tool: %+v", tools)
	}
	tl := tools[0]
	req, err := tl.Decode([]byte(`{"type":"target","id":"host-1"}`))
	if err != nil || req.Resource == nil || req.Resource.Type != "target" {
		t.Fatalf("decode: %+v err=%v", req, err)
	}
	call, err := tl.BuildRequest(req)
	if err != nil || call.Method != "GET" || call.Path != "/api/v1/assistant/machine/contexts/target/host-1" {
		t.Fatalf("build: %+v err=%v", call, err)
	}
	if err := tl.Validate([]byte(`{"correlation_id":"c","context":{}}`)); err != nil {
		t.Fatalf("valid output rejected: %v", err)
	}
	if tl.Validate([]byte(`{"correlation_id":"c","context":{},"extra":1}`)) == nil {
		t.Fatal("extra key accepted")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd assistant/mcp && go test ./internal/modules/context/`
Expected: FAIL.

- [ ] **Step 3: Write minimal implementation**

```go
// context.go
package context

import (
	"net/url"

	"hunter.local/assistant/mcp/internal/resource"
	"hunter.local/assistant/mcp/internal/tool"
)

type Module struct{}

func (Module) Tools() []tool.Tool {
	return []tool.Tool{{
		Name:             "get_selected_context",
		Description:      "Return one explicitly granted sanitized Hunter context record.",
		InputSchema:      resource.Schema,
		OutputSchema:     tool.ResultSchema,
		RequiresResource: true,
		Decode:           decode,
		BuildRequest:     buildRequest,
		Validate:         func(p []byte) error { return validateKeys(p, []string{"correlation_id", "context"}) },
	}}
}

func decode(args []byte) (tool.Request, error) {
	in, err := resource.Decode(args)
	if err != nil {
		return tool.Request{}, err
	}
	return tool.Request{Payload: in, Resource: &tool.Resource{Type: in.Type, ID: in.ID}}, nil
}

func buildRequest(req tool.Request) (tool.Call, error) {
	r := req.Resource
	return tool.Call{
		Method: "GET",
		Path:   "/api/v1/assistant/machine/contexts/" + url.PathEscape(r.Type) + "/" + url.PathEscape(r.ID),
	}, nil
}
```

```go
// util.go
package context

import (
	"encoding/json"

	"hunter.local/assistant/mcp/internal/codec"
)

var errRejected = codec.ErrInvalid

// validateKeys enforces that payload is a closed object with exactly required keys.
func validateKeys(payload []byte, required []string) error {
	var root map[string]json.RawMessage
	if err := codec.DecodeRawClosed(payload, &root); err != nil {
		return err
	}
	if !codec.ExactKeys(root, required) {
		return errRejected
	}
	return nil
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd assistant/mcp && go test ./internal/modules/context/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add assistant/mcp/internal/modules/context/
git commit -m "Add the context module for the get_selected_context MCP tool."
```

---

### Task 9: `modules/artifacts` — get_artifact_example

**Files:**
- Create: `assistant/mcp/internal/modules/artifacts/artifacts.go`
- Create: `assistant/mcp/internal/modules/artifacts/util.go`
- Test: `assistant/mcp/internal/modules/artifacts/artifacts_test.go`

**Interfaces:**
- Produces: `artifacts.Module{}` with tool `get_artifact_example`, `RequiresResource: true`, `InputSchema: resource.Schema`, `OutputSchema: tool.ResultSchema`, output keys `{"correlation_id","artifact"}`.
- Decode differs from context: after `resource.Decode`, reject unless `Type ∈ {"whiterabbit_template","ansible_playbook"}` (`handlers.go:179-181`). Path: `/api/v1/assistant/machine/artifacts/:type/:id`.

- [ ] **Step 1: Write the failing test**

```go
package artifacts

import "testing"

func TestArtifactExampleRestrictsType(t *testing.T) {
	tl := Module{}.Tools()[0]
	if _, err := tl.Decode([]byte(`{"type":"target","id":"x"}`)); err == nil {
		t.Fatal("non-artifact type accepted")
	}
	req, err := tl.Decode([]byte(`{"type":"ansible_playbook","id":"pb-1"}`))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	call, _ := tl.BuildRequest(req)
	if call.Path != "/api/v1/assistant/machine/artifacts/ansible_playbook/pb-1" {
		t.Fatalf("path: %s", call.Path)
	}
	if err := tl.Validate([]byte(`{"correlation_id":"c","artifact":{}}`)); err != nil {
		t.Fatalf("valid output rejected: %v", err)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd assistant/mcp && go test ./internal/modules/artifacts/`
Expected: FAIL.

- [ ] **Step 3: Write minimal implementation**

Mirror Task 8's `context.go`/`util.go`, changing: tool name/description to `get_artifact_example` / "Return one explicitly granted sanitized artifact example."; the path prefix to `/api/v1/assistant/machine/artifacts/`; output keys to `{"correlation_id","artifact"}`; and add to `decode` after `resource.Decode`:

```go
if in.Type != "whiterabbit_template" && in.Type != "ansible_playbook" {
	return tool.Request{}, codec.ErrInvalid
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd assistant/mcp && go test ./internal/modules/artifacts/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add assistant/mcp/internal/modules/artifacts/
git commit -m "Add the artifacts module for the get_artifact_example MCP tool."
```

---

### Task 10: `modules/policies` — get_authoring_policy

**Files:**
- Create: `assistant/mcp/internal/modules/policies/policies.go`
- Create: `assistant/mcp/internal/modules/policies/util.go`
- Test: `assistant/mcp/internal/modules/policies/policies_test.go`

**Interfaces:**
- Produces: `policies.Module{}` with tool `get_authoring_policy`, `RequiresResource: false`, `Scope: ""`, `InputSchema` = the `artifactSchema` from `catalog.go:32-37`, `OutputSchema: tool.ResultSchema`, output keys `{"correlation_id","policy"}`.
- Input type `artifactInput{ArtifactType string json:"artifact_type"}`; decode rejects unless `artifact_type ∈ {"whiterabbit_template","ansible_playbook"}` (`handlers.go:183-188,251-253`). No resource. Path `/api/v1/assistant/machine/policies/:artifact_type`.

- [ ] **Step 1: Write the failing test**

```go
package policies

import "testing"

func TestAuthoringPolicy(t *testing.T) {
	tl := Module{}.Tools()[0]
	if tl.RequiresResource {
		t.Fatal("policy tool must not require a resource")
	}
	req, err := tl.Decode([]byte(`{"artifact_type":"whiterabbit_template"}`))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if req.Resource != nil {
		t.Fatal("policy decode must not set a resource")
	}
	call, _ := tl.BuildRequest(req)
	if call.Path != "/api/v1/assistant/machine/policies/whiterabbit_template" {
		t.Fatalf("path: %s", call.Path)
	}
	if _, err := tl.Decode([]byte(`{"artifact_type":"target"}`)); err == nil {
		t.Fatal("bad artifact_type accepted")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd assistant/mcp && go test ./internal/modules/policies/`
Expected: FAIL.

- [ ] **Step 3: Write minimal implementation**

Implement `Module`, `artifactInput`, `decode` (`codec.DecodeClosed` + type check), `buildRequest` (`"/api/v1/assistant/machine/policies/" + url.PathEscape(in.ArtifactType)`), and reuse the `validateKeys` helper (copy into this package's `util.go`) with `{"correlation_id","policy"}`. Include the `artifactSchema` JSON verbatim from `catalog.go:32-37` as the `InputSchema`.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd assistant/mcp && go test ./internal/modules/policies/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add assistant/mcp/internal/modules/policies/
git commit -m "Add the policies module for the get_authoring_policy MCP tool."
```

---

### Task 11: `modules/validation` — validation-result and draft-validation tools

**Files:**
- Create: `assistant/mcp/internal/modules/validation/validation.go`
- Create: `assistant/mcp/internal/modules/validation/schema.go`
- Create: `assistant/mcp/internal/modules/validation/output.go`
- Create: `assistant/mcp/internal/modules/validation/util.go`
- Test: `assistant/mcp/internal/modules/validation/validation_test.go`

**Interfaces:**
- Produces: `validation.Module{}` with three tools — `get_validation_result` (GET `/api/v1/assistant/machine/validation_results/:id`), `validate_whiterabbit_draft` (POST `/api/v1/assistant/machine/validations/whiterabbit_template`), `validate_ansible_draft` (POST `/api/v1/assistant/machine/validations/ansible_playbook`). All `RequiresResource: false`, `Scope: ""`, `OutputSchema: tool.ResultSchema`.
- `schema.go`: the `validationResultSchema`, `whiterabbitSchema`, `ansibleSchema` JSON verbatim from `catalog.go:38-76`.
- `output.go` (free functions → this is the module's rich validator): move `validateValidationOutput` (`handlers.go:295-372`), the `validationOutput`/`validationDetails`/`ansibleNormalized` structs (`handlers.go:79-98`), and the `uuidPattern`/`codePattern`/`digestPattern` regexps (`handlers.go:31-33`). The per-tool allowed-keys `{"correlation_id","validation"}` gate plus the `validateValidationOutput(tool, root)` dispatch (`handlers.go:259-293`, validation branch only) become each tool's `Validate`.
- `util.go` (free functions): move `validateWhiterabbit` (`handlers.go:227-242`), `validateAnsible` (`handlers.go:244-249`), and the input structs `whiterabbitInput/whiterabbitDraft/whiterabbitCommand/ansibleInput/ansibleDraft/validationResultInput` (`handlers.go:49-77`).
- Request bodies for the POST tools: `json.Marshal(input)`; reject if `> 64<<10` bytes (`handlers.go:127-129`).

- [ ] **Step 1: Write the failing test**

```go
package validation

import "testing"

func TestValidationTools(t *testing.T) {
	byName := map[string]bool{}
	for _, tl := range (Module{}).Tools() {
		byName[tl.Name] = true
	}
	for _, want := range []string{"get_validation_result", "validate_whiterabbit_draft", "validate_ansible_draft"} {
		if !byName[want] {
			t.Fatalf("missing tool %s", want)
		}
	}
}

func TestWhiterabbitDraftRoundTrip(t *testing.T) {
	var wr Tool // helper to fetch by name below
	for _, tl := range (Module{}).Tools() {
		if tl.Name == "validate_whiterabbit_draft" {
			wr = tl
		}
	}
	body := `{"draft":{"name":"n","commands":[{"command":"curl","args":["-s"]}]}}`
	req, err := wr.Decode([]byte(body))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	call, err := wr.BuildRequest(req)
	if err != nil || call.Method != "POST" || call.Path != "/api/v1/assistant/machine/validations/whiterabbit_template" {
		t.Fatalf("build: %+v err=%v", call, err)
	}
	if len(call.Body) == 0 {
		t.Fatal("expected marshaled body")
	}
}

func TestWhiterabbitValidateOutputRejectsExtraKey(t *testing.T) {
	var wr Tool
	for _, tl := range (Module{}).Tools() {
		if tl.Name == "validate_whiterabbit_draft" {
			wr = tl
		}
	}
	if wr.Validate([]byte(`{"correlation_id":"c","validation":{},"x":1}`)) == nil {
		t.Fatal("extra key accepted")
	}
}
```

Note: replace the `var wr Tool` helper pattern with a small local `find(name string) tool.Tool` helper in the test; `Tool` is `tool.Tool`.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd assistant/mcp && go test ./internal/modules/validation/`
Expected: FAIL.

- [ ] **Step 3: Write minimal implementation**

Create the four files, moving the cited functions/structs/regexps verbatim (only adjusting package and any exported-name needs). Each tool's `Decode` uses `codec.DecodeClosed` + the matching `validate*` guard (returning `codec.ErrInvalid` on failure) and sets `Resource: nil`. `BuildRequest` builds the GET/POST `tool.Call` (marshaling the draft for POSTs, enforcing the 64 KiB cap). Each tool's `Validate` runs the allowed-keys `{"correlation_id","validation"}` check then `validateValidationOutput(<toolName>, root)`.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd assistant/mcp && go test ./internal/modules/validation/`
Expected: PASS.

- [ ] **Step 5: Add inline output-rejection cases, then commit**

Add table-driven cases to `validation_test.go` asserting each tool's `Validate` **rejects** malformed output: extra top-level key, missing `validation`, a `validation` object with an unknown field, and (for `validate_whiterabbit_draft`) a `status`/`valid` mismatch. (The shared cross-tool *input* adversarial fixture is ported at the runner level in Task 13, not here.) Then:

```bash
git add assistant/mcp/internal/modules/validation/
git commit -m "Add the validation module for the validation-result and draft-validation MCP tools."
```

---

### Task 12: Golden catalog parity test

**Files:**
- Create: `assistant/mcp/internal/runner/catalog_golden_test.go`
- Create: `assistant/mcp/internal/runner/testdata/catalog_golden.json`

**Interfaces:**
- Consumes: `runner.NewRegistry`, all four `modules/*`, `tool.Tool`.
- Purpose: prove the advertised catalog (Name, Description, normalized InputSchema, normalized OutputSchema) built from the new modules matches the pre-refactor catalog exactly.

- [ ] **Step 1: Create the golden fixture**

Create `testdata/catalog_golden.json` — a JSON array of `{name,description,input_schema,output_schema}` objects, one per tool, with **schemas normalized** (parsed and re-serialized so whitespace is irrelevant). Populate it from the current `internal/tools/catalog.go`: the six entries (`catalog.go:83-88`) with `input_schema` = the schema each references (`resourceSchema` for `get_selected_context`/`get_artifact_example`, `artifactSchema` for `get_authoring_policy`, `validationResultSchema`/`whiterabbitSchema`/`ansibleSchema` for the validation tools) and `output_schema` = `outputSchema` for all six.

- [ ] **Step 2: Write the failing test**

```go
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

func normalize(t *testing.T, raw json.RawMessage) string {
	var v any
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatalf("bad schema JSON: %v", err)
	}
	out, _ := json.Marshal(v)
	return string(out)
}

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
			t.Errorf("%s description drift", tl.Name)
		}
		if normalize(t, tl.InputSchema) != normalize(t, g.InputSchema) {
			t.Errorf("%s input schema drift", tl.Name)
		}
		if normalize(t, tl.OutputSchema) != normalize(t, g.OutputSchema) {
			t.Errorf("%s output schema drift", tl.Name)
		}
	}
}
```

- [ ] **Step 3: Run test to verify it passes**

Run: `cd assistant/mcp && go test ./internal/runner/ -run TestCatalogMatchesGolden`
Expected: PASS (the new modules reproduce the exact advertised catalog).

- [ ] **Step 4: Commit**

```bash
git add assistant/mcp/internal/runner/catalog_golden_test.go assistant/mcp/internal/runner/testdata/
git commit -m "Assert the migrated MCP catalog matches the pre-refactor advertised catalog."
```

---

### Task 13: Cut over `main.go`, delete the monolith, verify green

**Files:**
- Modify: `assistant/mcp/cmd/hunter-mcp/main.go:14-18,35-49`
- Delete: `assistant/mcp/internal/tools/` (catalog.go, handlers.go, handlers_test.go, adversarial_fixture_test.go)
- Delete: `assistant/mcp/internal/hunter/` (client.go, client_test.go)
- Modify (if referenced): `assistant/mcp/fuzz_test.go`, `assistant/mcp/cmd/hunter-mcp/main_test.go`

**Interfaces:**
- Consumes: `runner.NewRegistry/New/Register`, `transport.NewClient`, all four modules, `redact.NewChecker`, `config`, `auth`.

- [ ] **Step 1: Rewire main.go**

Replace the `hunter`/`tools` imports and construction (`main.go:14-18,35-49`) with:

```go
transportClient, err := transport.NewClient(
	settings.HunterBaseURL,
	settings.HunterServiceToken,
	settings.RequestTimeout,
	settings.MaxResponseBytes,
)
if err != nil {
	log.Fatal("hunter-mcp client configuration rejected")
}

registry := runner.NewRegistry()
registry.Add(
	contextmod.Module{},
	artifacts.Module{},
	policies.Module{},
	validation.Module{},
)
run := runner.New(transportClient, registry, redact.NewChecker(int(settings.MaxResponseBytes)))
// ... server construction unchanged ...
runner.Register(server, run)
```

Add the imports for `runner`, `transport`, and the four `modules/*` packages (aliasing `context` → `contextmod` to avoid clashing with the stdlib `context` import).

- [ ] **Step 2: Port the cross-tool adversarial input fixture to the runner**

Create `assistant/mcp/internal/runner/adversarial_test.go`. It reads the shared fixture at `../../../testdata/adversarial/tool_inputs.json` (same relative depth as the old `internal/tools` location, so the path is unchanged), builds a full registry (all four modules), and for each case maps the outcome:

```go
func decodeOutcome(reg *Registry, name string, args []byte) string {
	t, ok := reg.Lookup(name)
	if !ok {
		return PublicError(ErrUnknownTool)
	}
	if _, err := t.Decode(args); err != nil {
		return PublicError(ErrInvalidInput)
	}
	return ""
}
```

Reproduce the three generators verbatim from `internal/tools/adversarial_fixture_test.go:31-42` (`oversized_source`, `deep_json`, `malformed_utf8`). Assert `decodeOutcome(reg, case.Tool, args) == case.Expected` for every case — this keeps the guarantee that `shell`, `list_all_targets`, `get_service_token`, `save_template`, `send_job`, `schedule_job`, `execute_playbook` all resolve to `unknown_tool`.

Run: `cd assistant/mcp && go test ./internal/runner/ -run TestAdversarial`
Expected: PASS.

- [ ] **Step 3: Retarget the fuzz test**

Edit `assistant/mcp/fuzz_test.go`: replace the `internal/tools` import with `internal/resource` and the body call `tools.DecodeExactResource(input)` with `resource.Decode(input)` (seed corpus unchanged).

- [ ] **Step 4: Delete the old packages**

```bash
git rm -r assistant/mcp/internal/tools assistant/mcp/internal/hunter
```

`main_test.go` imports only `internal/auth` (verified), so it needs no change.

- [ ] **Step 5: Build and test the whole module**

Run: `cd assistant/mcp && go build ./... && go test ./...`
Expected: PASS across every package; no reference to `internal/tools` or `internal/hunter` remains.

- [ ] **Step 6: Confirm no dangling references**

Run: `cd assistant/mcp && grep -rn "internal/tools\|internal/hunter" . || echo "clean"`
Expected: `clean`.

- [ ] **Step 7: Commit**

```bash
git add -A assistant/mcp
git commit -m "Cut the MCP server over to the modular runner and delete the monolithic tools and hunter packages."
```

---

## Self-Review

**Spec coverage:**
- §4 target architecture (`tool`, `runner`, `transport`, `modules/*`) → Tasks 1,4,5,6,7,8–11,13. ✓
- §4.1 `Tool` contract (self-describing, `Call` in `tool`) → Task 1. ✓
- §4.2 runner pipeline order + gates → Task 6 (+ Task 7 wiring). ✓
- §4.3 transport replaces `routes` map → Task 4, 13. ✓
- §4.4 registration via `reg.Add(...)` → Tasks 5, 13. ✓
- Migrated six tools 1:1 → Tasks 8–11. ✓
- §5 read scope: the runner **gate** and `Grant.ReadScopes` field are added now (Task 4, 6); the Rails column/issuer/authorizer are Phase 2 (out of scope for this plan, stated in header). ✓
- §10 testing: per-package unit tests, adversarial fixtures (Task 11), golden parity (Task 12). ✓
- §11 Phase 1 = this plan; Phases 2a–2c explicitly deferred. ✓

**Placeholder scan:** No "TBD"/"handle edge cases"/"similar to Task N". Verbatim moves cite exact source line ranges + new home + names. ✓

**Type consistency:** `tool.Tool` fields (`Decode`/`BuildRequest`/`Validate`, `Scope`, `RequiresResource`) are used identically in Tasks 6–12. `runner.New(backend, registry, checker)` signature matches its call in Tasks 6, 12, 13. `transport.NewClient(baseURL, serviceToken, timeout, maxResponseBytes)` matches Task 13's call. `transport.Grant.ReadScopes` (Task 4) is read in Task 6's scope gate. Module package name `context` is aliased `contextmod` at every import site (Tasks 12, 13). ✓

**Note on `context` package name:** the module directory is `modules/context` with `package context`; every importer aliases it `contextmod` because files also import the stdlib `context`. The module's own files do **not** need stdlib `context`, so no clash inside the package.
