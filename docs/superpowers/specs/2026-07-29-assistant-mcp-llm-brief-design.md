# Assistant MCP LLM Brief — Design

**Status:** DRAFTED, PENDING REVIEW. Date: 2026-07-29.

## Problem

The Assistant LLM can call the 20 read-only MCP tools (Phase 2c + Path B), but it
has almost no guidance on *how* to use each one: the free-text/dork syntax, the
exact filters, id formats, pagination, and that everything is read-only. Tool
`Description`s are one-liners and the generated input schemas expose fields
(`q`, `status`, `program`, …) as bare typed values with no explanation. The LLM
therefore guesses at dork syntax and filter semantics.

## Goal

Give the LLM a compact, complete, accurate brief on every read tool — filters,
free-text/dork grammar, id formats, pagination, read-only nature — delivered
through **native MCP surfaces** so it travels with the server, is versioned with
the tools, needs no change to the locked-down Claude backend, and is
golden-tested.

Non-goals: write/execute tools (none exist; a separate governed effort);
documenting the non-domain authoring tools (`get_selected_context`,
`get_artifact_example`, `get_authoring_policy`, draft validation); mounted
`.md` skills / CLAUDE.md (blocked by the `--strict-mcp-config` +
`--allowedTools "mcp__hunter__*"` lockdown — the CLI has no `Skill`/`Read` tool,
and widening the allowlist would break the read-only boundary).

## Scope

The 20 domain read tools: `list_targets`/`get_target`, `list_cves`/`get_cve`,
`list_vulnerabilities`/`get_vulnerability`, `list_endpoints`/`get_endpoint`,
`list_programs`/`get_program`, `list_templates`/`get_template`,
`list_jobs`/`get_job`, `list_playbooks`/`get_playbook`,
`list_run_groups`/`get_run_group`, `get_run`, `list_run_events`.

## Architecture — three MCP-native surfaces

The go MCP SDK (v1.6.0) already supports each surface; nothing new is mounted.

### 1. Server-level `Instructions` (cross-cutting brief)

Set once via `mcp.ServerOptions{Instructions: hunterInstructions}` in
`assistant/mcp/cmd/hunter-mcp/main.go` (the SDK delivers it to the client on
`initialize` — `protocol.go:720`, `server.go:62`). A single compact Go const
covering:

- **Read-only:** these tools only read; they never create/update/delete/run/send.
- **Listing & counting:** every `list_*` returns `{correlation_id, count, page,
  limit, items[]}`; `count` is the total match count (use it to answer "how
  many" without paging). Pagination: `page` (1-based) + `limit` (default/max 50;
  `list_run_events` max 100).
- **Detail:** every `get_*` takes an `id`; the id format varies by tool
  (integer for sitemap/Control-Center tools; `CVE-…`/`GHSA-…` for `get_cve`;
  Mongo ObjectId hex for `get_vulnerability`; program `sid` for `get_program`;
  alive-target id for `get_target`).
- **Free-text / dork `q`:** the shared grammar — bare words match free text;
  `key:value` terms filter by field; multiple terms AND together; quote values
  with spaces; `-key:value` negates; `*` wildcards where supported. Which tools
  accept `q` and their key sets are stated in each tool's own description and the
  `q` field description. 1–2 worked examples (e.g. sitemap
  `path:/admin status:200`, programs `platform:hackerone bounty:yes`).
- **Discovery habit:** consult each tool's description and input-schema field
  descriptions for its exact filters and dork keys before calling it.

### 2. Enriched per-tool `Description`

Each `list_*` description names its exact filters, whether it accepts `q` and
its **dork keys**, and one example. Each `get_*` names its id format. These
descriptions already exist as one-liners on each module's `Spec`
(`ListDesc`/`GetDesc`); this enriches them.

### 3. Per-field input-schema `description`s

A new `Description string` on `readmodule.ListField`, emitted by
`build.go`'s `listSchema` as the field's JSON-schema `description`. Every list
field gets a terse description; the load-bearing ones are `q` (dork keys +
example) and the non-obvious filters (`status` = HTTP status family,
`min_severity`, `has_fix`, `methods`, `scope_count_gte`, `after_counter`, …).
`page`/`limit` get one-line descriptions too.

## Builder change (the only code-shape change)

`readmodule.ListField` gains `Description string`. `build.go` `listSchema`
sets `m["description"] = f.Description` when non-empty. `page`/`limit` get
fixed descriptions in `listSchema`. `Build`/`BuildList`/`BuildGet` and the
closed-input/closed-output validators are unchanged (descriptions are advertised
metadata; they never affect decode/validation). No change to `Spec.Scope`,
tool names, id patterns, projections, or the security lockdown.

## Content sourcing & the Rails↔Go contract

The brief's facts are owned by the Rails side and must match it:

- **Filters** — the machine controller `params.permit(...)` list + the Go
  `Spec.ListFields`.
- **Dork keys** — the Rails `SearchParser::KEYS` for the modules that have one:
  `Sitemap::SearchParser`, `Programs::SearchParser`, `Vulnerabilities::SearchParser`,
  `Targets::SearchParser`. `cves` has **no** dork parser (plain filters + plain
  free-text substring) — its `q`/filters are documented as such.
- **id format** — the Go `IDPattern` (and the Rails route `constraints`).
- **`MAX_LIMIT`** — the machine controller constant (50; run_events 100).

The Go module description text is therefore a documented contract with these
Rails sources, exactly like the existing projection ↔ Go-output-validator
lockstep. Each Go module carries a comment pointing at its Rails `SearchParser`
(or "no dork parser") as source of truth. Cross-language (Ruby↔Go) sync is not
machine-enforced; it is seeded correct by the extraction task below and guarded
by the review + golden.

## Coverage assurance ("analyze everything")

The implementation plan's **first task is a systematic per-module extraction**
that produces one table per module — filters, dork support + exact keys, id
format, `MAX_LIMIT`, and the projected `summary`/`full` fields — read directly
from the code (controllers, `SearchParser`s, `IDPattern`s, projections). That
table is the single source the descriptions are written from, so no filter or
dork key is missed. The table is recorded in the plan for review.

## Testing

- **Catalog golden** (`assistant/mcp/internal/runner/testdata/catalog_golden.json`)
  already snapshots each tool's `name`/`description`/`input_schema`/`output_schema`;
  the enriched descriptions + new field `description`s update it (regenerated,
  reviewed).
- **New Go tests:** (a) the server `Instructions` is non-empty and states
  read-only + the dork grammar; (b) per module, each `q` field's `description`
  contains that module's dork keys, and each `list_*`/`get_*` description is
  non-empty and (for `get_*`) names an id format. These are presence/content
  assertions on the advertised catalog, not behavioral changes.
- No Rails test change (the brief is Go-side advertised metadata). The existing
  runner scope/secret-rejection and closed-schema tests are unaffected.

## Rollout

The brief is inert data until the client reads it, and the Claude backend picks
it up automatically on the next `hunter-mcp` rebuild (`docker compose up
--build`, `pull_policy: build`). No env, no lockdown change, no new surface.

## Self-review checklist (for the implementer)

Every list tool: filters + (dork keys | "no dork") + example in its description;
every list field: a `description`; every get tool: id format named; server
`Instructions`: read-only + pagination + count + id-format-varies + dork grammar
+ examples. Dork keys match the Rails `SearchParser::KEYS` verbatim.
