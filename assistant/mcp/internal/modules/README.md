# Assistant MCP read modules — module contract

Every Assistant read-only `list_*`/`get_*` tool pair is a self-contained Go
package under `internal/modules/<m>/`, built on the shared
`internal/readmodule` builder. Adding a new module is exactly these five
mechanical edits (see the Rails-side mirror at
`web/app/controllers/api/v1/assistant/machine/README.md` for the other half
of the pair):

1. **Rails read source** — reuse the module's existing `MongoSource`/`Query`/AR
   scope; no new data layer.
2. **Rails projection** — an explicit `summary`/`full` string-keyed allowlist
   service on the Rails side (never the raw record).
3. **Rails controller** — a `< Api::V1::Assistant::Machine::ReadController`
   controller supplying only the read source + projection.
4. **Rails wiring** — two routes under `assistant/machine`, plus the scope
   slug in `TurnGrant::READ_SCOPES` and the tool names in `Issuer::TOOLS`.
5. **Go module** — `internal/modules/<m>/module.go`, a `Module` type whose
   `Tools()` returns `readmodule.Build(spec)` for a `readmodule.Spec`
   describing:
   - `ListTool` / `GetTool` — the two dedicated, independently-scoped tool
     names (never a single parameterized `read(module)` tool).
   - `Scope` — the read scope slug, identical to the Rails
     `TurnGrant::READ_SCOPES` / `Issuer::TOOLS` entry.
   - `BasePath` — the `/api/v1/assistant/machine/<m>` route root.
   - `DetailKey` — the key the `get_*` tool nests its result under.
   - `ListFields` — the closed set of list/filter query params.
   - `SummaryKeys` / `FullKeys` — the closed output-validation allowlists,
     kept in lockstep with the Rails projection's `summary`/`full` keys.

   Then register `<m>.Module{}` in `cmd/hunter-mcp/main.go`, extend that
   binary's golden test, and extend the catalog golden fixture.

`internal/readmodule` (see `internal/modules/targets/targets.go` for the
reference usage) supplies the JSON schema generation, closed input decoding,
safe-id handling, and closed output validation — a module's `module.go` only
needs to describe its `Spec`, not reimplement any of that machinery. The
`targets` module (Phase 2b, refactored in Task A2) is the current concrete
reference; the `cves` module is the intended next one once it lands.
