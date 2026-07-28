# Assistant MCP — Modular Runner + Read-Only Module Tools

- **Date:** 2026-07-28
- **Status:** Approved (design)
- **Scope:** `assistant/mcp` (Go) + `web` Rails machine namespace + turn-grant model
- **Related:** `docs/superpowers/specs/2026-07-27-assistant-claude-code-backend-design.md`,
  `AGENTS.md` "Assistant capability change rule"

## 1. Purpose

The Assistant chat works, but the MCP tool layer is a monolith
(`internal/tools/{catalog.go,handlers.go}` — all tool definitions, input
decoding, output validation, and routing in two files) coupled to a single
tool→path map in `internal/hunter/client.go`. It does not scale to the goal:

> The LLM should answer questions like *"how many targets match `*.example.com`"*
> or *"give me all login targets"* by **querying and filtering whole Hunter
> modules** (targets, CVEs, vulnerabilities, templates, Whiterabbit, Ansible, …)
> using the MCP as its factual source of reference. Read-only first; more
> capability added incrementally over time.

This spec defines two things:

1. **Phase 1 — Reorganization (no behavior change).** Restructure the MCP into
   one Go package per module, a central **runner** that owns all cross-cutting
   security logic once, and a generic **transport**. Migrate the existing six
   tools 1:1.
2. **Phase 2 — Read-only module tools.** Add `list_*` / `get_*` tools for each
   Hunter module, backed by new grant-gated machine endpoints that delegate to
   the existing module services, gated by a new per-module **read scope**.

The organizing principle: **adding the next module must be trivial and local** —
a new package + one registration line + one machine endpoint, with zero edits to
shared security code.

## 2. Goals / Non-Goals

**Goals**
- Each module that touches a distinct Hunter API surface is its **own internal
  Go package**. Free functions (not bound to a struct) live in that package's
  `util.go`.
- A single **runner** performs grant introspection, authorization (tool + scope
  + resource), budget reservation, dispatch, redaction, and closed output
  validation — exactly once, for every tool.
- Read tools support **server-side filtering, search, and counting** so the LLM
  gets accurate answers without pulling whole collections.
- The design honors the **Assistant capability change rule**: closed per-tool
  schemas, dedicated per-module scopes (never a wildcard "read anything" tool),
  metadata-only audit, adversarial tests, UI disclosure.

**Non-Goals (YAGNI)**
- No write, send, execute, or schedule tools. Read-only only.
- No proxying of the public `/api/v1/<module>` API. All access stays inside the
  `/api/v1/assistant/machine/*` namespace.
- No OpenAPI codegen / plugin system. Modules are hand-written Go.
- No new provider or model behavior. Chat plumbing is unchanged.
- No cross-module "join"/aggregation tools. One module per tool.

## 3. Current Architecture (what we are replacing)

- `internal/tools/catalog.go` — every `Definition` (name, description, in/out
  schema) hard-coded in one `NewCatalog`; `Register` wires the MCP server.
- `internal/tools/handlers.go` (416 lines) — `Handler.Call` does grant
  introspection, tool/resource/budget checks, a per-tool `switch` for input
  decode, the Hunter call, redaction, and a per-tool `switch` for output
  validation. All tool-specific logic is interleaved with cross-cutting logic.
- `internal/hunter/client.go` — a `routes map[string]func(type,id) string`
  couples each tool name to its machine path; `Get`/`Post` switch on tool name.
- Shared, already well-factored: `internal/auth` (grant-from-context),
  `internal/limits` (per-grant call/byte budget), `internal/redact` (secret
  scanner), `internal/config`.

The security model (preserved verbatim): the MCP authenticates to Rails with a
service bearer token **and** forwards `X-Hunter-Turn-Grant`. Rails
`Grants::Authorizer` checks the grant is unexpired/unrevoked, the tool is in
`grant.tools`, resource tools match an explicit `{type,id}` in `grant.resources`,
and reserves budget (≤8 calls, byte caps) with full audit.

## 4. Target Architecture (Phase 1)

```
assistant/mcp/internal/
  tool/            Shared contracts (no Hunter/HTTP deps):
                     - Tool:   Name, Description, InputSchema, OutputSchema,
                               Scope, ResourceKind, Decode, BuildRequest, Validate
                     - Request/Response value types
                     - Call{Method, Path, Body}: a pure request descriptor
                       (transport consumes it; keeps `tool` HTTP-free)
                     - Module interface: Tools() []Tool
  runner/          THE RUNNER. Owns the whole pipeline, once:
                     Registry (name -> Tool + owning module)
                     Dispatch(ctx, grant, name, args):
                       decode(closed) -> introspect grant -> tool allowed?
                       -> scope allowed? -> resource allowed? (if ResourceKind)
                       -> budget.Reserve -> transport call -> redact.Check
                       -> Validate(closed) -> wrap {result: ...}
                     Register(server, registry): binds each Tool to the MCP SDK.
  transport/       Generic authenticated client to the machine namespace:
                     Do(ctx, method, path, grant, body) ([]byte, error)
                     (URL/redirect/size/content-type guards from today's client)
  modules/
    context/       get_selected_context        (migrated 1:1)
    artifacts/     get_artifact_example         (migrated 1:1)
    policies/      get_authoring_policy         (migrated 1:1)
    validation/    get_validation_result,
                   validate_whiterabbit_draft,
                   validate_ansible_draft        (migrated 1:1)
  auth/ limits/ redact/ config/    unchanged shared plumbing
```

### 4.1 The `tool.Tool` contract

A module contributes a slice of `Tool` values. Each `Tool` is fully
self-describing; the runner needs no per-tool `switch`:

```go
type Tool struct {
    Name         string
    Description  string
    InputSchema  json.RawMessage        // closed JSON Schema (advertised to LLM)
    OutputSchema json.RawMessage        // closed JSON Schema (advertised to LLM)
    Scope        string                 // read scope required, e.g. "targets"; "" = always-allowed
    ResourceKind string                 // "" unless an explicit resource grant is required

    // Decode validates+parses closed input into an opaque Request.
    Decode func(args []byte) (Request, error)
    // BuildRequest maps a decoded Request to a concrete machine call.
    BuildRequest func(r Request) (Call, error)  // Call is defined in this package
    // Validate enforces the closed output shape on the raw payload.
    Validate func(payload []byte) error
}

type Module interface { Tools() []Tool }
```

- `Decode`, `BuildRequest`, `Validate` are the only module-specific code. Each is
  a small pure function → they live in the module package (struct methods in
  `<module>.go`, free helpers in `util.go`).
- The runner treats `Scope` and `ResourceKind` declaratively — no hard-coded tool
  lists (today's `RESOURCE_TOOLS`, allowed-keys map, etc. become per-tool data).

### 4.2 The runner pipeline (single source of truth)

`runner.Dispatch` replaces `Handler.Call`. The order and semantics are exactly
today's, but expressed once and driven by `Tool` metadata:

1. Reject empty grant.
2. `tool.Decode(args)` — closed-schema decode (`DisallowUnknownFields`, size/UTF-8
   caps, regex/range checks). Failure → `invalid_tool_input`.
3. `transport`-side `Introspect(grant)`; check expiry.
4. `grant.Tools` contains `Name`? else `turn_grant_rejected`.
5. If `Tool.Scope != ""`: `grant.ReadScopes` contains `Scope`? else
   `scope_not_granted` (**new**).
6. If `Tool.ResourceKind != ""`: requested `{type,id}` ∈ `grant.Resources`? else
   `resource_not_granted` (unchanged path for the migrated tools).
7. `budget.Reserve(...)`.
8. `transport.Do(BuildRequest(req))`.
9. `redact.Check(payload)` and `tool.Validate(payload)` → else
   `tool_response_rejected`.
10. Wrap `{ "result": <payload> }`, return structured content.

Public error mapping (`publicError`) stays identical and centralized.

### 4.3 Transport

`internal/hunter/client.go` splits: the HTTP hardening (URL validation, redirect
refusal, response size cap, `application/json` enforcement, service-token +
grant headers) moves into `transport.Client.Do(ctx, method, path, grant, body)`.
The `routes` map and tool-name `switch`es are deleted — each module's
`BuildRequest` returns a `tool.Call{Method, Path, Body}` that `transport.Do`
consumes. `Introspect` (grant introspection) stays on the transport since it is
grant-scoped, not tool-scoped.

### 4.4 Registration

```go
// cmd/hunter-mcp/main.go
reg := runner.NewRegistry()
reg.Add(context.Module{...}, artifacts.Module{...}, policies.Module{...},
        validation.Module{...})            // Phase 1
// Phase 2 appends: targets.Module{}, cves.Module{}, vulnerabilities.Module{}, ...
runner.Register(server, reg)
```

Adding a module = construct it, pass it to `reg.Add`. Nothing else in `runner`,
`transport`, `auth`, `limits`, or `redact` changes.

## 5. Read Scope — the one new authorization primitive (Phase 2)

Filtered browsing cannot be expressed as an explicit `{type,id}` allowlist, so we
add a **per-module read scope** to the grant. It is the minimal, closed
extension needed and the only genuine threat-model expansion.

**Data model.** New column `assistant_turn_grants.read_scopes` (`jsonb`, default
`[]`, not null) — a set of module slugs (`"targets"`, `"cves"`, …). Added to
`TurnGrant::IMMUTABLE_ATTRIBUTES` (scope is frozen once issued). No wildcard
value is ever accepted; the issuer validates each entry against a fixed enum.

**Issuance.** `Grants::Issuer` populates `read_scopes` from a fixed catalog of
read-enabled modules. Because access is read-only over the user's own data, the
default is to grant the read scopes for modules the Assistant is configured to
read; a per-conversation/setting toggle can narrow this. `Grants::Authorizer`
gains a `scope` check: a tool carrying `Scope` requires that slug in
`grant.read_scopes`, raising `scope_not_allowed` otherwise. Resource tools are
unaffected.

**Budget.** Unchanged mechanism. Machine endpoints enforce **pagination + hard
result caps** so a single `list_*` call fits inside `max_result_bytes`; counts
are computed server-side and returned even when rows are capped, so *"how many"*
questions cost one small call.

**Audit.** Every read call is recorded metadata-only (correlation id, user,
conversation, turn, tool, scope, filter *shape* — never row contents), reusing
`Assistant::Audit`.

## 6. Machine Endpoints (Rails, Phase 2)

New read routes under the existing `namespace :machine`, each backed by a thin
controller that delegates to the module's **existing** service and serializes a
**bounded, redaction-safe projection** (not the full public `as_json`):

```
get "targets",      to: "targets#index"     # filter/search/paginate -> {count,page,limit,items}
get "targets/:id",  to: "targets#show"       # full record projection
get "cves", "cves/:id"
get "vulnerabilities", "vulnerabilities/:id"
... (templates, whiterabbit, ansible, sitemap, programs as added)
```

- `Machine::TargetsController#index` calls `Targets::MongoSource.all/count` with
  `Targets::SearchParser` (so `q=*.example.com` and expression filters work) and
  returns `{count, page, limit, items:[summary]}`. `#show` returns one record via
  `.find`.
- Controllers reuse `Machine::BaseController` (service-token + grant
  authorization + `Grants::Authorizer.reserve!` with the tool's scope).
- Each endpoint defines an explicit **projection allowlist** of fields exposed to
  the model; anything not listed is dropped (defense in depth alongside the Go
  `redact` + closed `Validate`).

## 7. Read Tool Shapes (Phase 2 template)

Two tools per module, consistent everywhere. Example — **targets**:

- `list_targets` — closed input `{ q?, program?, status?, page?, limit? }`
  (`limit` clamped, `q` length-capped). Output (closed):
  `{ correlation_id, count, page, limit, items: [ {id, host, program, status} ] }`.
  Answers *"how many targets match `*.example.com`"* (read `count`) and
  *"give me all login targets"* (paginate `items`).
- `get_target` — closed input `{ id }` (safe-id regex). Output (closed):
  `{ correlation_id, target: { …projection… } }`.

`cves`, `vulnerabilities`, `templates`, `whiterabbit`, `ansible`, `sitemap`,
`programs` follow the identical `list_*` / `get_*` shape, each with its own
closed schemas and projection. `list_*` always returns `count`, so counting
never requires fetching rows.

## 8. Capability-Rule Compliance

| Requirement (AGENTS.md)            | How this design satisfies it                              |
|------------------------------------|-----------------------------------------------------------|
| Dedicated closed schema            | Per-tool `InputSchema`/`OutputSchema` + `Decode`/`Validate`|
| Dedicated authorization            | Per-module **read scope**; no wildcard; immutable on grant |
| No generic/broadened tool          | One `list_*`/`get_*` per module; no generic `read(module)` |
| Clear UI disclosure                | Chat UI lists which modules the Assistant can read (§9)     |
| Metadata-only audit                | `Assistant::Audit` per call; filter *shape* only, no rows  |
| Adversarial tests, stable outcomes | Per-module adversarial fixtures (unknown fields, oversize, |
|                                    | scope/resource escalation, output-shape violations)        |
| Human approval for effectful ops   | N/A — read-only; no effectful operation exists             |

## 9. UI Disclosure

The chat surface states, per conversation, which modules the Assistant can read
(derived from the granted `read_scopes`). No new write/execute affordance is
introduced. (Exact placement handled with the frontend work; the requirement is
that the capability is visible, not silent.)

## 10. Testing Strategy

- **Phase 1 (pure Go, runs here):** migrate existing `handlers_test.go`,
  `adversarial_fixture_test.go`, `catalog` and client tests onto the new
  packages. A `runner` test asserts the pipeline order and every `publicError`
  mapping. Golden test: the advertised catalog (names + schemas) is byte-identical
  before and after the refactor — proves 1:1 migration.
- **Phase 2 Go:** each module package gets unit tests (closed decode, output
  validate) and adversarial fixtures (unknown field, oversize input, wrong
  output keys, scope-less grant, resource escalation) with **stable** rejected
  outcomes.
- **Phase 2 Rails:** machine-controller integration tests (service double, no
  live Mongo per repo convention) asserting scope enforcement, projection
  allowlist, pagination caps, count correctness, and metadata-only audit.

## 11. Phasing & Migration

1. **Phase 1 — Reorg (no behavior change).** Introduce `tool`, `runner`,
   `transport`; migrate the six tools into `modules/*`; delete the monolith and
   the `routes` map; keep the catalog byte-identical (golden test). Mergeable on
   its own; fully verifiable with `go test`.
2. **Phase 2a — Read scope.** Migration + `TurnGrant` + `Grants::Issuer/Authorizer`
   + `Machine::BaseController` scope check. No tools yet.
3. **Phase 2b — First read module (targets).** `modules/targets` + machine
   endpoints + UI disclosure. This is the reference implementation.
4. **Phase 2c — Remaining modules.** cves, vulnerabilities, templates,
   whiterabbit, ansible, sitemap, programs — each a mechanical repeat of 2b.

Each phase is independently reviewable and testable. Production stays disabled
until each capability's review evidence is recorded in the Assistant production
checklist (per AGENTS.md).

## 12. Open Questions

- Exact default for `read_scopes` at issuance (all read-enabled modules vs. an
  explicit per-conversation opt-in). Resolved during Phase 2a; does not block
  Phase 1.
- Whether `list_*` needs a separate cheap `count_*` tool or the embedded `count`
  suffices (current lean: embedded `count` is enough — fewer tools).
