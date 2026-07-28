# Assistant MCP Read Tools — Phase 2c (Remaining Read Modules) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Assistant read-only `list_*`/`get_*` tools for every remaining module — cves, vulnerabilities, sitemap, programs, and Control Center (templates, jobs, ansible playbooks/run-groups/runs/run-events) — reusing the proven `targets` (Phase 2b) pattern, but first extracting shared scaffolding so each module is a small, self-contained, low-boilerplate addition.

**Architecture:** Two shared seams are introduced up front and the existing `targets` module is refactored onto them (behavior identical, catalog re-verified): (1) a Go `internal/readmodule` builder that emits a dedicated, independently-named, independently-scoped `list_*`/`get_*` tool pair from a per-module `Spec` while preserving closed input schemas, closed output validation, exact-key projection allowlists and a safe-id pattern; (2) a Rails `Api::V1::Assistant::Machine::ReadController` base that standardizes machine auth, pagination clamps, the response envelope and not-found handling, leaving each controller to supply only its own read source + projection. Every module is then its own self-contained Go package (`internal/modules/<m>`) and its own Rails slice (a `MongoSource`/read source, a `Assistant::Machine::<M>Projection` allowlist, one machine controller), registered in exactly one place each. Read-only only; no write/execute/send tools.

**Tech Stack:** Ruby 3.3.6 / Rails 8 (Postgres + MongoDB), Go 1.25.12 MCP service, Minitest, `go test`.

## Global Constraints

- **Read-only only.** No write/execute/send/schedule tools. Per AGENTS.md capability rule: no generic "read any module" tool — one dedicated `list_*`/`get_*` pair per module, each with its own closed schemas and its own independently-revocable read scope. No wildcard scopes.
- **The `readmodule` builder is code reuse, not a generic runtime tool.** It is a compile-time helper that emits *dedicated, narrowly-named, per-module-scoped* tools with per-module closed allowlists. Each tool remains independently named and independently revocable. It must not introduce a `read(module)`-style parameterized tool.
- **Every response field is an explicit projection allowlist** — never the raw Mongo doc or the raw ActiveRecord record. The Rails projection (`summary`/`full`) and the Go closed output validator are a lockstep contract pair (change both or the Go `Validate` rejects the response).
- **Secret exclusions are mandatory and enumerated per module below.** Never project: vulnerability raw `request`/`response` HTTP or `poc.curl`/`poc.extracted`/`poc.llm_reasoning`; ansible credential `private_key`/`ssh_password`/`private_key_passphrase`/`become_password` (the four `encrypts` columns); `run_groups.execution_payload` (encrypted, resolved secrets); run snapshot `playbook_yaml`/`inventory_yaml`/`known_hosts`/`lease_digest`.
- **Machine endpoints live only under `/api/v1/assistant/machine/*`.** Each enforces `authorize_tool!(tool, scope:)` (service token + turn grant + scope + budget) and returns via `complete_machine_response!`. Machine requests have **no `Current.user`** — read the same global scopes the public controllers already read; never rely on user ownership.
- **`MAX_LIMIT = 50`** on every list (except `list_run_events`, cursor-paginated, max 100 to match the existing controller). `read_scopes` is immutable at issue and never a wildcard.
- Rails tests double Mongo / stub the read source (no live Mongo/Postgres data). Go tests run under `assistant/mcp`. Commit author `Claude <noreply@anthropic.com>`, one-sentence messages. Rails: `bin/rails test` from `web/` (needs Postgres `hunter_test`). Go: `go test ./...` from `assistant/mcp/`.
- **Scope slugs (exact strings, identical in Rails `TurnGrant::READ_SCOPES` / `Issuer::TOOLS` / controllers and Go `Spec.Scope`):** `cves`, `vulnerabilities`, `sitemap`, `programs`, `control_center_templates`, `control_center_jobs`, `control_center_ansible`. (`control_center_credentials` only if the flagged optional Task is approved.)

---

## Module contract (the "how to add a module" reference)

After Part A lands, adding a new read module is exactly these five mechanical edits — documented in `assistant/mcp/internal/modules/README.md` and `web/app/controllers/api/v1/assistant/machine/README.md`:

1. **Rails read source** — reuse the module's existing `MongoSource`/`Query`/AR scope (no new data layer).
2. **Rails projection** — `app/services/assistant/machine/<m>_projection.rb` with `summary(record)` and `full(record)` returning explicit string-keyed allowlists.
3. **Rails controller** — `app/controllers/api/v1/assistant/machine/<m>_controller.rb < ReadController`, ~15 lines: `authorize_tool!`, fetch, project, `list_response`/`detail_response`.
4. **Rails wiring** — two routes in the `assistant/machine` namespace; add the scope slug to `TurnGrant::READ_SCOPES` and the tool names to `Issuer::TOOLS`.
5. **Go module** — `internal/modules/<m>/module.go` returning `readmodule.Build(spec)`; register `<m>.Module{}` in `cmd/hunter-mcp/main.go` and the golden test; extend the catalog golden fixture.

---

# PART A — Shared scaffolding (do first; everything else depends on it)

### Task A1: Go `readmodule` builder — closed list/get tool pair from a Spec

**Files:**
- Create: `assistant/mcp/internal/readmodule/spec.go`
- Create: `assistant/mcp/internal/readmodule/build.go`
- Create: `assistant/mcp/internal/readmodule/validate.go`
- Test: `assistant/mcp/internal/readmodule/readmodule_test.go`

**Interfaces:**
- Consumes: `tool` (`tool.Tool`, `tool.Request`, `tool.Call`, `tool.ResultSchema`), `codec` (`DecodeRawClosed`, `ExactKeys`, `SafeID`, `ErrInvalid`).
- Produces:
  - `readmodule.ListField{ Name string; Kind string /* "string"|"int" */; MaxLen int; Min int; Max int }`.
  - `readmodule.Spec{ ListTool, GetTool, Scope, BasePath, DetailKey, ListDesc, GetDesc string; ListFields []ListField; SummaryKeys []string; FullKeys []string; IDPattern *regexp.Regexp /* nil ⇒ codec.SafeID */; MaxItems int /* 0 ⇒ 50 */ }`.
  - `readmodule.Build(spec Spec) []tool.Tool` — returns exactly two tools (`list_*`, `get_*`), each with `Scope: spec.Scope`, `OutputSchema: tool.ResultSchema`, generated closed `InputSchema`, and generated `Decode`/`BuildRequest`/`Validate`.
  - Package-level `readmodule.UUIDPattern` (the correlation-id regex) reused by validators.

- [ ] **Step 1: Write the failing test** (`readmodule_test.go`)

```go
package readmodule

import (
	"regexp"
	"testing"

	"hunter.local/assistant/mcp/internal/tool"
)

func spec() Spec {
	return Spec{
		ListTool: "list_things", GetTool: "get_thing", Scope: "things",
		BasePath: "/api/v1/assistant/machine/things", DetailKey: "thing",
		ListDesc: "List things.", GetDesc: "Get one thing.",
		ListFields: []ListField{
			{Name: "q", Kind: "string", MaxLen: 200},
			{Name: "status", Kind: "string", MaxLen: 40},
		},
		SummaryKeys: []string{"id", "name"},
		FullKeys:    []string{"id", "name", "detail"},
	}
}

func find(t *testing.T, tools []tool.Tool, name string) tool.Tool {
	t.Helper()
	for _, x := range tools {
		if x.Name == name {
			return x
		}
	}
	t.Fatalf("tool %q not built", name)
	return tool.Tool{}
}

func TestBuildListRequest(t *testing.T) {
	tl := find(t, Build(spec()), "list_things")
	if tl.Scope != "things" {
		t.Fatalf("scope %q", tl.Scope)
	}
	req, err := tl.Decode([]byte(`{"q":"*.example.com","limit":10}`))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	call, err := tl.BuildRequest(req)
	if err != nil || call.Method != "GET" {
		t.Fatalf("build: %+v %v", call, err)
	}
	if call.Path != "/api/v1/assistant/machine/things?limit=10&q=%2A.example.com" {
		t.Fatalf("path: %s", call.Path)
	}
}

func TestListRejectsUnknownField(t *testing.T) {
	tl := find(t, Build(spec()), "list_things")
	if _, err := tl.Decode([]byte(`{"q":"x","evil":1}`)); err == nil {
		t.Fatal("unknown field accepted")
	}
}

func TestListRejectsWrongType(t *testing.T) {
	tl := find(t, Build(spec()), "list_things")
	if _, err := tl.Decode([]byte(`{"limit":"big"}`)); err == nil {
		t.Fatal("string limit accepted")
	}
}

func TestGetValidatesID(t *testing.T) {
	tl := find(t, Build(spec()), "get_thing")
	if _, err := tl.Decode([]byte(`{"id":"../etc"}`)); err == nil {
		t.Fatal("unsafe id accepted")
	}
	req, err := tl.Decode([]byte(`{"id":"abc123"}`))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	call, _ := tl.BuildRequest(req)
	if call.Path != "/api/v1/assistant/machine/things/abc123" {
		t.Fatalf("path: %s", call.Path)
	}
}

func TestGetHonorsCustomIDPattern(t *testing.T) {
	s := spec()
	s.IDPattern = regexp.MustCompile(`^[0-9]+$`)
	tl := find(t, Build(s), "get_thing")
	if _, err := tl.Decode([]byte(`{"id":"abc"}`)); err == nil {
		t.Fatal("non-numeric id accepted under numeric pattern")
	}
	if _, err := tl.Decode([]byte(`{"id":"42"}`)); err != nil {
		t.Fatalf("numeric id rejected: %v", err)
	}
}

func TestListOutputValidation(t *testing.T) {
	tl := find(t, Build(spec()), "list_things")
	good := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","count":1,"page":1,"limit":50,` +
		`"items":[{"id":"t1","name":"n"}]}`
	if err := tl.Validate([]byte(good)); err != nil {
		t.Fatalf("valid rejected: %v", err)
	}
	extra := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","count":1,"page":1,"limit":50,` +
		`"items":[{"id":"t1","name":"n","EXTRA":1}]}`
	if tl.Validate([]byte(extra)) == nil {
		t.Fatal("extra item key accepted")
	}
}

func TestGetOutputValidation(t *testing.T) {
	tl := find(t, Build(spec()), "get_thing")
	good := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","thing":{"id":"t1","name":"n","detail":"d"}}`
	if err := tl.Validate([]byte(good)); err != nil {
		t.Fatalf("valid rejected: %v", err)
	}
	bad := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","thing":{"id":"t1","name":"n"}}`
	if tl.Validate([]byte(bad)) == nil {
		t.Fatal("missing full key accepted")
	}
}
```

- [ ] **Step 2: Run it to verify failure**

Run: `cd assistant/mcp && go test ./internal/readmodule/`
Expected: FAIL (package absent).

- [ ] **Step 3: Write `spec.go`**

```go
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
	ListTool string
	GetTool  string
	Scope    string
	BasePath string // "/api/v1/assistant/machine/<segment>"
	DetailKey string // envelope key for get_* ("cve", "target", ...)
	ListDesc string
	GetDesc  string

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
```

- [ ] **Step 4: Write `build.go`** (schemas, decode, request building)

```go
package readmodule

import (
	"encoding/json"
	"net/url"
	"regexp"
	"strconv"
	"strings"

	"hunter.local/assistant/mcp/internal/codec"
	"hunter.local/assistant/mcp/internal/tool"
)

// Build returns the module's two tools.
func Build(spec Spec) []tool.Tool {
	idPattern := spec.IDPattern
	if idPattern == nil {
		idPattern = codec.SafeID
	}
	return []tool.Tool{
		{
			Name: spec.ListTool, Description: spec.ListDesc,
			InputSchema: listSchema(spec), OutputSchema: tool.ResultSchema,
			Scope:        spec.Scope,
			Decode:       decodeList(spec),
			BuildRequest: buildList(spec),
			Validate:     validateList(spec),
		},
		{
			Name: spec.GetTool, Description: spec.GetDesc,
			InputSchema: getSchema(idPattern), OutputSchema: tool.ResultSchema,
			Scope:        spec.Scope,
			Decode:       decodeGet(idPattern),
			BuildRequest: buildGet(spec),
			Validate:     validateGet(spec),
		},
	}
}

func listSchema(spec Spec) json.RawMessage {
	props := map[string]any{
		"page":  map[string]any{"type": "integer", "minimum": 1, "maximum": 100000},
		"limit": map[string]any{"type": "integer", "minimum": 1, "maximum": spec.maxItems()},
	}
	for _, f := range spec.ListFields {
		if f.Kind == "int" {
			m := map[string]any{"type": "integer"}
			if f.Min != 0 || f.Max != 0 {
				m["minimum"], m["maximum"] = f.Min, f.Max
			}
			props[f.Name] = m
			continue
		}
		m := map[string]any{"type": "string"}
		if f.MaxLen > 0 {
			m["maxLength"] = f.MaxLen
		}
		props[f.Name] = m
	}
	schema := map[string]any{"type": "object", "additionalProperties": false, "properties": props}
	out, _ := json.Marshal(schema)
	return out
}

func getSchema(idPattern *regexp.Regexp) json.RawMessage {
	schema := map[string]any{
		"type": "object", "additionalProperties": false, "required": []string{"id"},
		"properties": map[string]any{
			"id": map[string]any{"type": "string", "minLength": 1, "maxLength": 255, "pattern": idPattern.String()},
		},
	}
	out, _ := json.Marshal(schema)
	return out
}

// decodeList closed-decodes into a raw map, then rejects any key outside the
// allowed set and any value whose JSON type is wrong for its field.
func decodeList(spec Spec) func([]byte) (tool.Request, error) {
	allowed := map[string]string{"page": "int", "limit": "int"}
	for _, f := range spec.ListFields {
		allowed[f.Name] = f.Kind
	}
	return func(args []byte) (tool.Request, error) {
		var raw map[string]json.RawMessage
		if err := codec.DecodeRawClosed(args, &raw); err != nil {
			return tool.Request{}, codec.ErrInvalid
		}
		for key, val := range raw {
			kind, ok := allowed[key]
			if !ok || !typeMatches(kind, val) {
				return tool.Request{}, codec.ErrInvalid
			}
		}
		return tool.Request{Payload: raw}, nil
	}
}

func typeMatches(kind string, val json.RawMessage) bool {
	trimmed := strings.TrimSpace(string(val))
	switch kind {
	case "int":
		_, err := strconv.Atoi(trimmed)
		return err == nil
	case "string":
		return len(trimmed) > 0 && trimmed[0] == '"'
	}
	return false
}

func buildList(spec Spec) func(tool.Request) (tool.Call, error) {
	order := append([]string{}, "limit", "page")
	for _, f := range spec.ListFields {
		order = append(order, f.Name)
	}
	return func(req tool.Request) (tool.Call, error) {
		raw := req.Payload.(map[string]json.RawMessage)
		values := url.Values{}
		for key, val := range raw {
			values.Set(key, scalarString(val))
		}
		path := spec.BasePath
		if enc := values.Encode(); enc != "" {
			path += "?" + enc
		}
		return tool.Call{Method: "GET", Path: path}, nil
	}
}

// scalarString renders a validated string/int raw value as its query text.
func scalarString(val json.RawMessage) string {
	trimmed := strings.TrimSpace(string(val))
	if len(trimmed) > 0 && trimmed[0] == '"' {
		var s string
		_ = json.Unmarshal(val, &s)
		return s
	}
	return trimmed
}

type getInput struct {
	ID string `json:"id"`
}

func decodeGet(idPattern *regexp.Regexp) func([]byte) (tool.Request, error) {
	return func(args []byte) (tool.Request, error) {
		var in getInput
		if err := codec.DecodeClosed(args, &in); err != nil || !idPattern.MatchString(in.ID) {
			return tool.Request{}, codec.ErrInvalid
		}
		return tool.Request{Payload: in}, nil
	}
}

func buildGet(spec Spec) func(tool.Request) (tool.Call, error) {
	return func(req tool.Request) (tool.Call, error) {
		in := req.Payload.(getInput)
		return tool.Call{Method: "GET", Path: spec.BasePath + "/" + url.PathEscape(in.ID)}, nil
	}
}
```

> Note: `codec.DecodeClosed`/`DecodeRawClosed` already reject empty, oversized (>64 KiB), invalid-UTF-8, and trailing-data input, so the generic decoder inherits those guarantees; the schema's `maxLength`/`pattern` are advertised to the model, and the decoder is the enforcing second line.

- [ ] **Step 5: Write `validate.go`** (closed output validation, parameterized)

```go
package readmodule

import (
	"encoding/json"
	"errors"

	"hunter.local/assistant/mcp/internal/codec"
)

var errRejected = errors.New("tool response rejected")

func validateList(spec Spec) func([]byte) error {
	max := spec.maxItems()
	return func(payload []byte) error {
		var root map[string]json.RawMessage
		if err := codec.DecodeRawClosed(payload, &root); err != nil {
			return err
		}
		if !codec.ExactKeys(root, []string{"correlation_id", "count", "page", "limit", "items"}) {
			return errRejected
		}
		var out struct {
			CorrelationID string                       `json:"correlation_id"`
			Count         int                          `json:"count"`
			Page          int                          `json:"page"`
			Limit         int                          `json:"limit"`
			Items         []map[string]json.RawMessage `json:"items"`
		}
		if json.Unmarshal(payload, &out) != nil || !UUIDPattern.MatchString(out.CorrelationID) {
			return errRejected
		}
		if out.Count < 0 || out.Page < 1 || out.Limit < 1 || out.Limit > max || len(out.Items) > out.Limit {
			return errRejected
		}
		for _, item := range out.Items {
			if !codec.ExactKeys(item, spec.SummaryKeys) {
				return errRejected
			}
		}
		return nil
	}
}

func validateGet(spec Spec) func([]byte) error {
	return func(payload []byte) error {
		var root map[string]json.RawMessage
		if err := codec.DecodeRawClosed(payload, &root); err != nil {
			return err
		}
		if !codec.ExactKeys(root, []string{"correlation_id", spec.DetailKey}) {
			return errRejected
		}
		var correlation string
		if json.Unmarshal(root["correlation_id"], &correlation) != nil || !UUIDPattern.MatchString(correlation) {
			return errRejected
		}
		var detail map[string]json.RawMessage
		if codec.DecodeRawClosed(root[spec.DetailKey], &detail) != nil {
			return errRejected
		}
		if !codec.ExactKeys(detail, spec.FullKeys) {
			return errRejected
		}
		return nil
	}
}
```

- [ ] **Step 6: Run tests to verify pass**

Run: `cd assistant/mcp && go test ./internal/readmodule/`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add assistant/mcp/internal/readmodule/
git commit -m "Add the readmodule builder that emits closed read-only tool pairs from a per-module spec."
```

---

### Task A2: Refactor `targets` onto the builder and re-verify the catalog

**Files:**
- Rewrite: `assistant/mcp/internal/modules/targets/targets.go` (now a `module.go`-style spec; delete `schema.go`, `util.go`, `output.go` content folded away)
- Delete: `assistant/mcp/internal/modules/targets/schema.go`, `.../util.go`, `.../output.go`
- Keep/adjust: `assistant/mcp/internal/modules/targets/targets_test.go` (path/decoding assertions still hold)
- Modify: `assistant/mcp/internal/runner/testdata/catalog_golden.json` (targets entries re-normalized if schema JSON formatting changed)

**Interfaces:**
- Consumes: `readmodule.Build`, `readmodule.Spec`.
- Produces: `targets.Module{}` unchanged externally — advertises `list_targets`/`get_target`, `Scope: "targets"`, same paths, same summary/full allowlists.

- [ ] **Step 1: Rewrite `targets.go`**

```go
// Package targets provides the read-only list_targets and get_target MCP tools.
package targets

import (
	"hunter.local/assistant/mcp/internal/readmodule"
	"hunter.local/assistant/mcp/internal/tool"
)

type Module struct{}

func (Module) Tools() []tool.Tool {
	return readmodule.Build(readmodule.Spec{
		ListTool: "list_targets", GetTool: "get_target", Scope: "targets",
		BasePath: "/api/v1/assistant/machine/targets", DetailKey: "target",
		ListDesc: "List and count alive targets, optionally filtered by query, program, or status.",
		GetDesc:  "Return the full record for one target by id.",
		ListFields: []readmodule.ListField{
			{Name: "q", Kind: "string", MaxLen: 200},
			{Name: "program", Kind: "string", MaxLen: 200},
			{Name: "status", Kind: "string", MaxLen: 40},
		},
		SummaryKeys: []string{"id", "host", "program", "status_code", "title"},
		FullKeys: []string{
			"id", "host", "program", "status_code", "title",
			"url", "status_family", "webserver", "content_type",
			"port", "scheme", "tech", "seen_at", "page_type",
		},
	})
}
```

- [ ] **Step 2: Delete the folded-away files**

Run: `cd assistant/mcp && git rm internal/modules/targets/schema.go internal/modules/targets/util.go internal/modules/targets/output.go`

- [ ] **Step 3: Reconcile `targets_test.go`**

The Phase 2b tests call `find(t, "list_targets")` on the module's tools and assert decode/path/output behavior — keep those, updating the `find` helper to iterate `Module{}.Tools()`. Remove any test that referenced the deleted unexported helpers (`listQuery`, `validID`, `validateListOutput`) directly; the behavior they covered is now covered by `readmodule_test.go` plus the black-box module tests.

- [ ] **Step 4: Run module + build**

Run: `cd assistant/mcp && go test ./internal/modules/targets/ && go build ./...`
Expected: PASS / build clean.

- [ ] **Step 5: Re-normalize and run the catalog golden**

Run: `cd assistant/mcp && go test ./internal/runner/ -run TestCatalogMatchesGolden`
If it fails only because the generated `input_schema` JSON for `list_targets`/`get_target` is key-ordered differently than the hand-written fixture, update those two fixture entries to the builder's output (behavior is identical; only schema serialization changed). Re-run to green. Any *semantic* schema difference (a missing constraint, changed maxLength) is a bug in the Spec — fix the Spec, not the fixture.

- [ ] **Step 6: Commit**

```bash
git add -A assistant/mcp/internal/modules/targets/ assistant/mcp/internal/runner/testdata/catalog_golden.json
git commit -m "Refactor the targets MCP module onto the readmodule builder with an identical catalog."
```

---

### Task A3: Rails `ReadController` base + machine pagination helpers

**Files:**
- Create: `web/app/controllers/api/v1/assistant/machine/read_controller.rb`
- Test: `web/test/integration/api/v1/assistant/machine/read_controller_test.rb` (via a throwaway subclass mounted in the test, or fold into the first real module's test — see note)

**Interfaces:**
- Consumes: `authorize_tool!`, `complete_machine_response!`, `machine_grant` (from `Machine::BaseController`).
- Produces (protected helpers for every read controller):
  - `machine_page` → `[params[:page].to_i, 1].max`.
  - `machine_limit(max)` → `params[:limit].blank? ? max : params[:limit].to_i.clamp(1, max)`.
  - `list_response(reservation, count:, page:, limit:, items:)` → `complete_machine_response!(reservation, { correlation_id:, count:, page:, limit:, items: })`.
  - `detail_response(reservation, key:, value:)` → `complete_machine_response!(reservation, { correlation_id:, key => value })`.
  - `machine_not_found(reservation)` → `reservation.fail!` then `render json: { error: "not_found" }, status: :not_found`.

- [ ] **Step 1: Write the base**

```ruby
module Api
  module V1
    module Assistant
      module Machine
        # Shared behavior for every read-only machine tool controller: pagination
        # clamps and the {correlation_id, ...} envelope. Auth/scope/budget come
        # from BaseController. Subclasses supply only their read source + projection.
        class ReadController < BaseController
          private

          def machine_page
            [ params[:page].to_i, 1 ].max
          end

          def machine_limit(max)
            return max if params[:limit].blank?

            params[:limit].to_i.clamp(1, max)
          end

          def list_response(reservation, count:, page:, limit:, items:)
            complete_machine_response!(reservation, {
              correlation_id: machine_grant.turn.correlation_id,
              count: count, page: page, limit: limit, items: items
            })
          end

          def detail_response(reservation, key:, value:)
            complete_machine_response!(reservation, {
              correlation_id: machine_grant.turn.correlation_id,
              key => value
            })
          end

          def machine_not_found(reservation)
            reservation.fail!
            render json: { error: "not_found" }, status: :not_found
          end
        end
      end
    end
  end
end
```

- [ ] **Step 2: Note on testing**

The base has no routes of its own; its behavior is exercised by every module controller test (Tasks B1+). Do not invent a fake route. This task's deliverable is verified when Task B1's `list_cves`/`get_cve` integration test passes against a controller that subclasses `ReadController`. Commit the base together with any doc, and let B1 prove it.

- [ ] **Step 3: Write the "how to add a module" docs**

Create `web/app/controllers/api/v1/assistant/machine/README.md` and `assistant/mcp/internal/modules/README.md`, each containing the five-step **Module contract** from the top of this plan (Rails-side and Go-side respectively), pointing at `targets` / `CveProjection` as the reference.

- [ ] **Step 4: Commit**

```bash
git add web/app/controllers/api/v1/assistant/machine/read_controller.rb web/app/controllers/api/v1/assistant/machine/README.md assistant/mcp/internal/modules/README.md
git commit -m "Add the Assistant machine ReadController base and the add-a-module module contract docs."
```

---

### Task A4: Grow the read-scope + tool allowlists for every Phase 2c module

**Files:**
- Modify: `web/app/models/assistant/turn_grant.rb` (`READ_SCOPES`)
- Modify: `web/app/services/assistant/grants/issuer.rb` (`TOOLS`)
- Test: `web/test/models/assistant/turn_grant_test.rb`, `web/test/services/assistant/grants/issuer_test.rb`

**Interfaces:**
- Produces: `TurnGrant::READ_SCOPES == %w[targets cves vulnerabilities sitemap programs control_center_templates control_center_jobs control_center_ansible]`; `Issuer::TOOLS` additionally includes every `list_*`/`get_*` name below.

- [ ] **Step 1: Write the failing tests** — assert the new scopes are accepted on a grant and that `Issuer.call` issues a grant whose `read_scopes == TurnGrant::READ_SCOPES` and whose `tools` include `list_cves`, `get_cve`, `list_vulnerabilities`, `get_vulnerability`, `list_endpoints`, `get_endpoint`, `list_programs`, `get_program`, `list_templates`, `get_template`, `list_jobs`, `get_job`, `list_playbooks`, `get_playbook`, `list_run_groups`, `get_run_group`, `get_run`, `list_run_events`.

- [ ] **Step 2: Run to verify failure** — `cd web && bin/rails test test/models/assistant/turn_grant_test.rb test/services/assistant/grants/issuer_test.rb` → FAIL.

- [ ] **Step 3: Extend `READ_SCOPES`** to the eight slugs above (keep it a frozen array; `read_scopes_are_known` now accepts them).

- [ ] **Step 4: Extend `Issuer::TOOLS`** with the eighteen tool names above (append; keep the existing write/validation tool names untouched).

- [ ] **Step 5: Run to verify pass** — same command → PASS.

- [ ] **Step 6: Commit**

```bash
git add web/app/models/assistant/turn_grant.rb web/app/services/assistant/grants/issuer.rb web/test/models/assistant/turn_grant_test.rb web/test/services/assistant/grants/issuer_test.rb
git commit -m "Grant the Phase 2c read scopes and read tools with every Assistant turn grant."
```

---

# PART B — Mongo modules (cves, vulnerabilities)

### Task B1: `cves` read module (reference for the module contract)

**Read source:** `Cves::MongoSource.all(filters:, search:, page:, limit:)` / `.count(filters:, search:)` / `.find(id)` (string CVE id). Filters permitted from params: `ecosystem, package, language, vendor, cwe, tag, has_fix, min_severity, published_after, modified_after`; free text via `params[:q]` → `search:`. **No expression/dork** (cves has no SearchParser). **No token `cve_filter`** on the machine path (no `Current.api_token`).

**Scope:** `cves`. **Tools:** `list_cves` / `get_cve`. **id pattern (Go):** `^CVE-[0-9]{4}-[0-9]+$` or fallback `codec.SafeID` — use `codec.SafeID` (CVE ids like `CVE-2024-1234` satisfy it; OSV ids like `GHSA-...` also satisfy it). **Detail key:** `cve`.

**Projection (`Assistant::Machine::CveProjection`):**
- `summary`: `id, summary, severity_level, severity_score, has_fix, modified`.
- `full`: summary + `details, aliases, published, withdrawn, cwe_ids, ecosystems, languages, vendors, tags, affected, references, chain, osv_id, first_seen_at, last_synced_at`.
- Secret/PII: none (public OSV data). Keep `details` out of `summary` for context budget.

**Files:** create `web/app/services/assistant/machine/cve_projection.rb`, `web/app/controllers/api/v1/assistant/machine/cves_controller.rb`; add routes `get "cves"`, `get "cves/:id"` in the `assistant/machine` namespace; create `web/test/integration/api/v1/assistant/machine/cves_test.rb`; create `assistant/mcp/internal/modules/cves/module.go` and `..._test.go`.

- [ ] **Step 1: Write the failing Rails integration test** — stub `Cves::MongoSource.all`/`.count`/`.find`; a grant with `read_scopes ["cves"]` + tools `list_cves`/`get_cve`. Assert (a) `list_cves` returns `{correlation_id, count, page, limit, items}` with each item's keys exactly the `summary` set; (b) list is `403 scope_not_allowed` under a grant without the `cves` scope; (c) `get_cve` returns `{correlation_id, cve}` with `full` keys; (d) `get_cve` of a missing id is `404 not_found`. Mirror `targets_test.rb` machine-header helpers.

- [ ] **Step 2: Run to verify failure** — `cd web && bin/rails test test/integration/api/v1/assistant/machine/cves_test.rb` → FAIL.

- [ ] **Step 3: Write `CveProjection`** — `summary(cve)` and `full(cve)` returning the exact string-keyed hashes above, reading `Cve` accessors (`cve.id`, `cve.summary`, `cve.severity_level`, …); `Array(cve.aliases)` etc. for list fields; `cve.chain` for the chain hash.

- [ ] **Step 4: Write `CvesController < ReadController`**

```ruby
module Api
  module V1
    module Assistant
      module Machine
        class CvesController < ReadController
          MAX_LIMIT = 50
          FILTERS = %i[ecosystem package language vendor cwe tag has_fix min_severity published_after modified_after].freeze

          def index
            reservation = authorize_tool!("list_cves", scope: "cves")
            filters = params.permit(*FILTERS).to_h
            search = params[:q].presence
            page = machine_page
            limit = machine_limit(MAX_LIMIT)
            count = ::Cves::MongoSource.count(filters: filters, search: search)
            items = ::Cves::MongoSource.all(filters: filters, search: search, page: page, limit: limit)
                                       .map { |cve| ::Assistant::Machine::CveProjection.summary(cve) }
            list_response(reservation, count: count, page: page, limit: limit, items: items)
          end

          def show
            reservation = authorize_tool!("get_cve", scope: "cves")
            cve = ::Cves::MongoSource.find(params[:id])
            return machine_not_found(reservation) unless cve

            detail_response(reservation, key: :cve, value: ::Assistant::Machine::CveProjection.full(cve))
          end
        end
      end
    end
  end
end
```

- [ ] **Step 5: Add routes** — in `namespace :machine` add `get "cves", to: "cves#index"` and `get "cves/:id", to: "cves#show"`.

- [ ] **Step 6: Run to verify pass** — `cd web && bin/rails test test/integration/api/v1/assistant/machine/cves_test.rb` → PASS.

- [ ] **Step 7: Write the Go module + test**

`assistant/mcp/internal/modules/cves/module.go`:

```go
// Package cves provides the read-only list_cves and get_cve MCP tools.
package cves

import (
	"hunter.local/assistant/mcp/internal/readmodule"
	"hunter.local/assistant/mcp/internal/tool"
)

type Module struct{}

func (Module) Tools() []tool.Tool {
	return readmodule.Build(readmodule.Spec{
		ListTool: "list_cves", GetTool: "get_cve", Scope: "cves",
		BasePath: "/api/v1/assistant/machine/cves", DetailKey: "cve",
		ListDesc: "List and count tracked CVEs, optionally filtered by ecosystem, package, severity, or fix status.",
		GetDesc:  "Return the full record for one CVE by id.",
		ListFields: []readmodule.ListField{
			{Name: "q", Kind: "string", MaxLen: 200},
			{Name: "ecosystem", Kind: "string", MaxLen: 100},
			{Name: "package", Kind: "string", MaxLen: 200},
			{Name: "language", Kind: "string", MaxLen: 100},
			{Name: "vendor", Kind: "string", MaxLen: 100},
			{Name: "cwe", Kind: "string", MaxLen: 40},
			{Name: "tag", Kind: "string", MaxLen: 100},
			{Name: "has_fix", Kind: "string", MaxLen: 5},
			{Name: "min_severity", Kind: "string", MaxLen: 10},
			{Name: "published_after", Kind: "string", MaxLen: 40},
			{Name: "modified_after", Kind: "string", MaxLen: 40},
		},
		SummaryKeys: []string{"id", "summary", "severity_level", "severity_score", "has_fix", "modified"},
		FullKeys: []string{
			"id", "summary", "severity_level", "severity_score", "has_fix", "modified",
			"details", "aliases", "published", "withdrawn", "cwe_ids", "ecosystems",
			"languages", "vendors", "tags", "affected", "references", "chain",
			"osv_id", "first_seen_at", "last_synced_at",
		},
	})
}
```

`module_test.go`: black-box tests mirroring `readmodule_test`'s pattern against `Module{}.Tools()` — scope, one list path with a filter, unknown-field rejection, a valid list-output document, and a valid get-output document with exactly the `FullKeys`.

- [ ] **Step 8: Run Go tests** — `cd assistant/mcp && go test ./internal/modules/cves/` → PASS.

- [ ] **Step 9: Commit**

```bash
git add web/app/services/assistant/machine/cve_projection.rb web/app/controllers/api/v1/assistant/machine/cves_controller.rb web/config/routes.rb web/test/integration/api/v1/assistant/machine/cves_test.rb assistant/mcp/internal/modules/cves/
git commit -m "Add the read-only cves machine endpoints and MCP module."
```

---

### Task B2: `vulnerabilities` read module

Same shape as B1. **Read source:** `Vulnerabilities::MongoSource.all(filters:, search:, page:, limit:)` / `.count(filters:, search:)` / `.find(id)` (BSON ObjectId string). Filters: `program, severity, status, tool`; free text `params[:q]` → `search:`. **id pattern (Go):** `codec.SafeID` (24-hex ObjectId satisfies it). **Scope:** `vulnerabilities`. **Tools:** `list_vulnerabilities`/`get_vulnerability`. **Detail key:** `vulnerability`.

**Projection (`Assistant::Machine::VulnerabilityProjection`)** — the model exposes only section hashes (`metadata/report/finding/target/poc`), so project explicit sub-fields:
- `summary`: `id, name (finding.name), severity (finding.severity), status (report.status), program (metadata.program)`.
- `full`: summary + `type (finding.type), cwe (finding.cwe), tags (finding.tags), tool (metadata.tool), asset (metadata.asset), date (metadata.date), description (metadata.description), impact (metadata.impact), host (target.host), url (target.url), ip (target.ip), port (target.port), submitted (report.submitted), status_updated_at (report.status_updated_at), confidence (poc.confidence)`.
- **MUST EXCLUDE (secret/PII):** top-level `request`/`response` raw HTTP (cookies, Authorization headers, tokens); `poc.curl`, `poc.extracted` (repro payloads w/ credentials); `poc.llm_reasoning` (internal); `report.status_updated_by`, `metadata.scan_id` (operator PII — omit).

- [ ] **Step 1–9:** identical sequence to B1 with the values above. The integration test MUST additionally assert that a stubbed doc containing `request`, `response`, and `poc.curl` produces a `full` payload whose keys are exactly the allowlist (proving the secret fields never appear). Go `module.go` uses `ListFields` `{q, program, severity, status, tool}` and the summary/full key lists above.

```bash
git add web/app/services/assistant/machine/vulnerability_projection.rb web/app/controllers/api/v1/assistant/machine/vulnerabilities_controller.rb web/config/routes.rb web/test/integration/api/v1/assistant/machine/vulnerabilities_test.rb assistant/mcp/internal/modules/vulnerabilities/
git commit -m "Add the read-only vulnerabilities machine endpoints and MCP module with secret-field exclusions."
```

---

# PART C — sitemap (Postgres/ActiveRecord adapter)

### Task C1: `sitemap` endpoints read module

**Read source (Postgres, not Mongo):** base scope `Sitemap::Endpoint.active`; filter via `Sitemap::EndpointFilter.apply(scope, params, free_text:, expression:, include_root:)`; parse `params[:q]` with `Sitemap::SearchParser.call` → `free_text`/`expression`. Paginate with `.order(:id).offset((page-1)*limit).limit(limit)`; count with `scope.count`. `find` = `Sitemap::Endpoint.active.find_by(id: params[:id])`. Program/host/scheme live on the associated `Sitemap::Target` (`endpoint.target`) — include the `:target` join when projecting those.

**Scope:** `sitemap`. **Tools:** `list_endpoints`/`get_endpoint`. **Detail key:** `endpoint`. **id pattern (Go):** `^[1-9][0-9]{0,18}$` (numeric bigint PK). **Filters permitted:** `path, has_query, content_type, methods (array), status (array)`.

**Projection (`Assistant::Machine::EndpointProjection`)** — read `endpoint.read_attribute(:method)` (avoid `Object#method`):
- `summary`: `id, url, path, method, status_code`.
- `full`: summary + `origin, content_type, content_length, first_seen_at, last_seen_at, program (target&.program), host (target&.host), scheme (target&.scheme), port (target&.port)`.
- Exclude: `target_id, crawl_mongo_id, url_digest` (internal join/dedup/binary).

- [ ] **Steps:** same TDD sequence as B1. Rails controller `EndpointsController < ReadController` under `app/controllers/api/v1/assistant/machine/sitemap/` (or flat `endpoints_controller.rb` — match the existing `assistant/machine` flat layout; use flat `SitemapEndpointsController` to avoid a nested module unless the namespace already exists). Routes: `get "sitemap/endpoints", to: "..."`, `get "sitemap/endpoints/:id", ..., constraints: { id: /\d+/ }`. Integration test stubs `Sitemap::Endpoint.active` scope + `EndpointFilter`/`SearchParser` (use `stub_methods`), asserts the summary/full key sets and numeric-id 404. Go `module.go` uses `BasePath: "/api/v1/assistant/machine/sitemap/endpoints"`, `IDPattern: regexp.MustCompile("^[1-9][0-9]{0,18}$")`, `ListFields` `{path, has_query, content_type, methods, status}` (all string; array filters are passed as comma-joined strings and split server-side — mirror how `EndpointFilter` reads `methods: []`/`status: []` by permitting `params[:methods]`/`params[:status]` as comma strings **or** arrays in the controller).

```bash
git add web/app/services/assistant/machine/endpoint_projection.rb web/app/controllers/api/v1/assistant/machine/sitemap_endpoints_controller.rb web/config/routes.rb web/test/integration/api/v1/assistant/machine/sitemap_endpoints_test.rb assistant/mcp/internal/modules/sitemap/
git commit -m "Add the read-only sitemap endpoints machine endpoints and MCP module."
```

---

# PART D — programs (Query adapter)

### Task D1: `programs` read module

**Read source (Mongo via Query engine):** `list` → `Programs::Query.call(qp)` returning `result.programs` (`[Program]`) + `result.total`; parse `params[:q]` with `Programs::SearchParser.call` → set `qp[:q]=free_text`, `qp[:dork_expression]=expression`. Pass empty favorite/trash sets (no `Current.user`). `get` → `Programs::Source.find(sid)`. Clamp `per_page` to `MAX_LIMIT=50`.

**Scope:** `programs`. **Tools:** `list_programs`/`get_program`. **Detail key:** `program`. **id pattern (Go):** `^[A-Za-z0-9][A-Za-z0-9:_-]{0,254}$` = `codec.SafeID` (sids are hex, `platform-slug`, or short tokens — all satisfy `SafeID`; do NOT constrain to hex). **Filters permitted:** `status, bounty, collaboration, scope_count_gte, scope_count_lte, reports_gte, platforms (array), scope_types (array), sort, dir`.

**Projection (`Assistant::Machine::ProgramProjection`)** — read `Program` accessors:
- `summary`: `sid, name, platform, public (public?), bounty_range`.
- `full`: summary + `slug, url, vdp (vdp?), bounty (bounty?), bounty_min, bounty_max, currency, reward_avg, reward_max, report_count, reports_24h, reports_7d, reports_month, avg_response_hrs, scope_count, collaboration (collaboration?), tags, languages, scope (asset/type pairs only), out_of_scope (asset/type pairs only)`.
- Exclude/omit (bloat or infra): `rules_html, account_access_html, qualifying_vulns, non_qualifying_vulns, description (or truncate), policy.restricted_ips, vpn_ips, vpn_active, required_user_agent`; never join per-user favorite/trash/view state.

- [ ] **Steps:** same TDD sequence. Trim `scope`/`out_of_scope` to `{asset, type}` pairs in the projection. Integration test stubs `Programs::Query.call` (returns a `Result`-like double with `programs`/`total`) and `Programs::Source.find`; asserts summary/full keys and that a program with `rules_html`/`vpn_ips` set yields a `full` payload whose keys are exactly the allowlist. Go `module.go`: `ListFields` per the permitted filters (arrays as comma strings), `IDPattern` omitted (defaults to `SafeID`).

```bash
git add web/app/services/assistant/machine/program_projection.rb web/app/controllers/api/v1/assistant/machine/programs_controller.rb web/config/routes.rb web/test/integration/api/v1/assistant/machine/programs_test.rb assistant/mcp/internal/modules/programs/
git commit -m "Add the read-only programs machine endpoints and MCP module."
```

---

# PART E — Control Center (Postgres/ActiveRecord)

All Control Center reads use the same **global** AR scopes the public controllers use (no `Current.user`). All ids are positive integers → Go `IDPattern: regexp.MustCompile("^[1-9][0-9]{0,18}$")`. Projections are metadata/field allowlists; large text fields (`yaml_content`, `stdout`, `stderr`, `event_data`) are `full`-only and bounded by the grant byte budget.

### Task E1: `control_center` templates + jobs (scope split)

**Templates — scope `control_center_templates`:** source `ControlCenter::Template.order(:name)` (list, clamp 50) / `find_by(id:)`. Tools `list_templates`/`get_template`, detail key `template`.
- `summary`: `id, name, kind, description, tags, updated_at`.
- `full`: summary + `output, commands, target, created_at`. (Drop `created_by` username.)

**Jobs — scope `control_center_jobs`:** source `ControlCenter::Job.order(created_at: :desc)` (list, clamp 50) / `find_by(id:)`. Tools `list_jobs`/`get_job`, detail key `job`.
- `summary`: `id, template_name, status, queue_name, target_count, exit_status, created_at`.
- `full`: summary + `stdout, stderr, updated_at`. **Keep omitting** `template_snapshot, selections, manual_targets, idempotency_key`.

- [ ] **Steps:** one Task, two controller/projection/Go-module sets (they share nothing but the pattern; commit together). `TemplatesController`/`JobsController < ReadController`. Routes under `namespace :machine`: `namespace :control_center do get "templates"; get "templates/:id"; get "jobs"; get "jobs/:id" end` (⇒ paths `/api/v1/assistant/machine/control_center/templates`…). Go modules `internal/modules/cc_templates/` and `internal/modules/cc_jobs/` with the matching base paths and integer id pattern. Integration tests stub the AR relations with `stub_methods` (return arrays of lightweight doubles exposing the projected attributes) — no live rows.

```bash
git add web/app/services/assistant/machine/control_center/ web/app/controllers/api/v1/assistant/machine/control_center/ web/config/routes.rb web/test/integration/api/v1/assistant/machine/control_center/ assistant/mcp/internal/modules/cc_templates/ assistant/mcp/internal/modules/cc_jobs/
git commit -m "Add the read-only Control Center templates and jobs machine endpoints and MCP modules."
```

### Task E2: `control_center` ansible playbooks + run-groups + runs + run-events

**Scope for all four: `control_center_ansible`.** Sources are the existing AR relations; ids integer.

- **Playbooks** — `ControlCenter::Ansible::Playbook` ordered by `lower(name)` / `find_by(id:)`. Tools `list_playbooks`/`get_playbook`, key `playbook`.
  - `summary`: `id, name, description, checksum, updated_at`.
  - `full`: summary + `yaml_content, variable_set_ids, created_at`. (`yaml_content` is validated-safe but large ⇒ full-only.)
- **Run groups** — `ControlCenter::Ansible::RunGroup` (offset paginated) / `find_by(id:)` with child run summaries. Tools `list_run_groups`/`get_run_group`, key `run_group`.
  - `summary`: `id, status, execution_mode, failure_policy, inventory_id, credential_id, started_at, completed_at, created_at`.
  - `full`: summary + `concurrency_limit, launch_snapshot, cancel_requested_at, updated_at, runs (array of run-summaries)`.
  - **NEVER project `execution_payload`** (encrypted, resolved secrets).
- **Runs** — `ControlCenter::Ansible::Run.find_by(id:)`. Tool `get_run` only (no list; listing is via run groups), key `run`.
  - `full`: `id, run_group_id, playbook_id, position, status, playbook_name, inventory_name, credential_name, credential_fingerprint, variable_audit, secret_variable_names, host_limit, check_mode, timeout_seconds, error_code, error_detail, exit_status, ok_count, changed_count, failed_count, unreachable_count, stored_event_bytes, truncated, queued_at, started_at, completed_at, cancel_requested_at, created_at, updated_at`.
  - **EXCLUDE** `playbook_yaml, inventory_yaml, known_hosts, lease_digest, runner_id`. (`variable_audit`/`secret_variable_names` are non-secret by construction — audit values omit secrets, names only.)
- **Run events** — `ControlCenter::Ansible::RunEvent` under a run, cursor-paginated by `after_counter`, max 100. Tool `list_run_events` (parented on `run_id`), returns items keyed `id, counter, event_uuid, parent_uuid, event_type, play, task, host, event_time, stdout, event_data, truncated, created_at`. Stdout/event_data are SecretRedactor-scrubbed at ingest; still bounded by byte budget.

- [ ] **Steps (TDD, one Task):**
  - Rails: `PlaybooksController`, `RunGroupsController`, `RunsController`, `RunEventsController < ReadController` under `.../machine/control_center/ansible/`; projections under `app/services/assistant/machine/control_center/ansible/`. Routes: nested `namespace :control_center { namespace :ansible { get "playbooks"; get "playbooks/:id"; get "run_groups"; get "run_groups/:id"; get "runs/:id"; get "runs/:run_id/events" } }`.
  - `get_run` and `list_run_events` use `authorize_tool!("get_run"/"list_run_events", scope: "control_center_ansible")`. `list_run_events` clamps `limit` to 100 and threads `after_counter` (a non-negative integer param) into the existing cursor query.
  - **Run-group projection test MUST assert** a stubbed group carrying `execution_payload` yields a `full` payload whose keys are exactly the allowlist (no `execution_payload`). **Run projection test MUST assert** a stubbed run carrying `playbook_yaml`/`known_hosts`/`lease_digest` yields exactly the allowlist.
  - Go: `internal/modules/cc_playbooks/`, `cc_run_groups/`, `cc_runs/`, `cc_run_events/`. `cc_runs` builds only `get_run` — since `readmodule.Build` always emits a pair, EITHER (a) also expose a `list_runs` backed by run-group children (out of scope) OR (b) add a `readmodule.BuildGet(spec)` / `readmodule.BuildList(spec)` split so a module can emit just one tool. **Choose (b):** add `BuildGet`/`BuildList` single-tool constructors to `build.go` (each returns `[]tool.Tool{...}` of length 1) and have `Build` call both; `cc_runs` uses `readmodule.BuildGet`; `cc_run_events` uses `readmodule.BuildList` with a `run_events`-shaped list whose items carry the run-event keys (extend `validateList` is unnecessary — item keys come from `SummaryKeys`, so set `SummaryKeys` to the run-event field list and `MaxItems: 100`). Update Task A1's `build.go` accordingly and add `BuildGet`/`BuildList` unit tests in `readmodule_test.go` when you reach this task (small back-edit; note it in the commit).

```bash
git add web/app/services/assistant/machine/control_center/ansible/ web/app/controllers/api/v1/assistant/machine/control_center/ansible/ web/config/routes.rb web/test/integration/api/v1/assistant/machine/control_center/ assistant/mcp/internal/modules/cc_playbooks/ assistant/mcp/internal/modules/cc_run_groups/ assistant/mcp/internal/modules/cc_runs/ assistant/mcp/internal/modules/cc_run_events/ assistant/mcp/internal/readmodule/
git commit -m "Add the read-only Control Center ansible playbooks, run-groups, runs, and run-events read tools."
```

### Task E3 (OPTIONAL — requires explicit approval): `control_center` credentials (metadata-only)

> **Do not implement without the operator's explicit go-ahead.** This is the only read tool that touches a secret-bearing table. It is metadata-only and its own independently-revocable scope, but per AGENTS.md the secret surface warrants a recorded threat-model note before shipping.

**Scope `control_center_credentials`** (add to `READ_SCOPES` + `Issuer::TOOLS` only in this task). Source `ControlCenter::Ansible::Credential`. Tools `list_credentials`/`get_credential`, key `credential`.
- Allowlist (metadata only): `id, name, auth_type, public_key_fingerprint, private_key_configured, ssh_password_configured, private_key_passphrase_configured, become_password_configured, last_used_at, created_at, updated_at`. (Consider dropping `username`.)
- **The projection must NEVER reference `private_key`, `ssh_password`, `private_key_passphrase`, `become_password`** (the four `encrypts` columns) — read only the `*_configured?` booleans and the derived fingerprint. Add an explicit test asserting a credential with all secrets set yields a payload whose keys are exactly the allowlist and whose values contain no secret material.

```bash
git commit -m "Add the read-only Control Center credentials metadata machine endpoint and MCP module."
```

---

# PART F — Registration, catalog, adversarial coverage, verification

### Task F1: Register every new module + extend the catalog golden

**Files:** `assistant/mcp/cmd/hunter-mcp/main.go`, `assistant/mcp/internal/runner/catalog_golden_test.go`, `assistant/mcp/internal/runner/testdata/catalog_golden.json`.

- [ ] **Step 1:** import and append to `registry.Add(...)` in `main.go`: `cves.Module{}, vulnerabilities.Module{}, sitemap.Module{}, programs.Module{}, cc_templates.Module{}, cc_jobs.Module{}, cc_playbooks.Module{}, cc_run_groups.Module{}, cc_runs.Module{}, cc_run_events.Module{}` (+ `cc_credentials.Module{}` iff E3 done).
- [ ] **Step 2:** register the same modules in `catalog_golden_test.go`.
- [ ] **Step 3:** regenerate the golden fixture entries for every new tool (name, description, builder-generated `input_schema`, shared `output_schema` = `ResultSchema`). Simplest: temporarily log `registry.Tools()` names+schemas from a scratch test, paste normalized JSON; or hand-write mirroring the builder output and let `TestCatalogMatchesGolden` confirm byte-parity.
- [ ] **Step 4:** Run `cd assistant/mcp && go test ./internal/runner/ -run 'TestCatalogMatchesGolden|TestAdversarialToolInputFixtures'` → PASS. The adversarial fixture's dangerous names (`execute_playbook`, `list_all_targets`, …) must still map to `unknown_tool`.
- [ ] **Step 5:** Commit — `git commit -m "Register the Phase 2c read modules and extend the catalog golden."`

### Task F2: End-to-end read-scope adversarial coverage through the runner

**Files:** `assistant/mcp/internal/runner/scope_adversarial_test.go` (extend).

- [ ] For each new scope, add a `Denied without scope` + `Allowed with scope` pair through `Runner.Dispatch` (mirror the Phase 2b `list_targets` tests), reusing `fakeBackend`. At minimum cover one Mongo (`list_cves`), one AR (`list_endpoints`), one Control Center (`list_templates`), and the secret-sensitive `get_run`/`get_run_group` (assert a backend payload carrying an extra `execution_payload` key is rejected by the module `Validate`). Run `go test ./internal/runner/` → PASS. Commit.

### Task F3: Full-suite verification

- [ ] **Go:** `cd assistant/mcp && go test -count=1 ./... && go vet ./... && gofmt -l .` → all pass; vet clean; `gofmt -l` empty.
- [ ] **Rails (targeted):** `cd web && bin/rails test test/models/assistant/turn_grant_test.rb test/services/assistant/grants/ test/integration/api/v1/assistant/machine/` → PASS. If Postgres `hunter_test` is unavailable, record that these were not run and must pass in CI/Docker before merge — do not claim success without the run.
- [ ] **No further commit** — verification only. Then hand off to `superpowers:finishing-a-development-branch`.

---

## Self-Review

**Spec coverage (design §11 Phase 2c "Remaining modules. cves, vulnerabilities, templates, whiterabbit, ansible, sitemap, programs — each a mechanical repeat of 2b"):**
- cves → B1 ✓; vulnerabilities → B2 ✓; sitemap → C1 ✓; programs → D1 ✓; whiterabbit templates+jobs → E1 ✓; ansible playbooks/run-groups/runs/run-events → E2 ✓; credentials → E3 (optional, flagged) ✓.
- §5 read-scope primitive reused; new slugs added immutably, no wildcard → A4 ✓.
- §6 machine endpoints delegate to existing services with explicit projection allowlists; no `Current.user` reliance → A3 base + every module Task ✓.
- §7 `list_*`/`get_*` shape with embedded `count`, closed schemas → readmodule builder A1 ✓.
- §8 capability rule: dedicated non-wildcard scope per module, closed schemas (generated), metadata-only audit (reuses `Authorizer`/`complete_machine_response!`), adversarial tests (F2) → ✓. No generic tool: the builder emits dedicated named/scoped tools, argued in Global Constraints ✓.
- User directive "each module its own internal pkg + easy to add": `internal/modules/<m>` per module + `readmodule` builder + Rails `ReadController` base + module-contract docs (A3) → ✓.

**Secret-exclusion coverage:** vulnerabilities request/response/poc.* (B2 test) ✓; ansible credentials four `encrypts` columns (E3 test) ✓; `execution_payload` (E2 run-group test + F2 validator test) ✓; run snapshots/lease_digest (E2 run test) ✓.

**Placeholder scan:** No "TBD"/"similar to Task N" without values — every module Task carries its concrete scope slug, tool names, id pattern, projection field lists, and read-source call. The one back-edit (BuildGet/BuildList split) is specified with its rationale in E2. ✓

**Type consistency:** Scope slugs are identical across A4 (`READ_SCOPES`), each controller's `authorize_tool!(scope:)`, and each Go `Spec.Scope`. Projection `summary`/`full` key lists (Rails) equal the Go `SummaryKeys`/`FullKeys` per module — the lockstep contract. `readmodule.Spec` field names in A1 match every module's usage in B–E. `list_response`/`detail_response`/`machine_page`/`machine_limit` signatures (A3) match all callers. ✓

**Note — projection/validator lockstep:** every Rails `<M>Projection` and its Go `SummaryKeys`/`FullKeys` are a contract pair; any future field change updates both or the Go closed `Validate` rejects the response. Intentional defense in depth.
