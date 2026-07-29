# Threat-model delta — Assistant Claude-backend MCP wiring (2026-07-29)

Status: **DRAFTED, PENDING INDEPENDENT REVIEW**

Base documents:

- `docs/superpowers/specs/2026-07-25-hunter-assistant-security-design.md`
- `docs/security/hunter-assistant-threat-model.md`
- `docs/security/hunter-assistant-production-checklist.md`
- `docs/superpowers/specs/2026-07-26-hunter-assistant-zero-step-activation-delta.md`
- `docs/superpowers/specs/2026-07-27-assistant-infra-simplification-delta.md`
- `AGENTS.md` — "Assistant capability change rule"
- `docs/superpowers/plans/2026-07-29-assistant-claude-mcp-wiring.md` (Path B plan; tasks PB1–PB3)

## What this delta covers

Tasks PB1–PB3 made the **default**, zero-step `assistant-claude` backend able
to invoke Hunter's MCP read tools — the same 20 read-only tools the legacy
`assistant-gateway` path has been authorized to call since Phase 2a–2c. Before
this change, the Claude backend issued no grant and held no MCP credential; it
could only draft text. After this change it presents a per-turn grant plus the
shared MCP bearer token to `hunter-mcp` exactly as the legacy gateway does.

This is a **transport and default-path change, not a capability change**: no
new tool is introduced, no tool gains a write/execute/send action, no scope is
widened beyond what Phase 2a–2c already approved, and no context type changes.
Per the Assistant capability change rule in `AGENTS.md`, this document is the
required delta recording the wiring, the controls that keep it read-only, the
one accepted new attribute of the shared MCP token, and the adversarial tests
that back the read-only lockdown.

## Capability

The default `assistant-claude` backend (the `claude` CLI, run as a subprocess
of `assistant/claude`) may now, for the duration of a single turn, call any of
the 20 already-approved `mcp__hunter__*` read tools (targets, CVEs,
vulnerabilities, sitemap endpoints, programs, Control Center templates/jobs/
playbooks/run-groups/runs/run-events) against `hunter-mcp`. It gains no
ability to write, execute, save, schedule, or send anything — Control Center's
existing persistence and execution paths remain the sole save/execution
authorities, unchanged by this delta.

## Controls

**Read-only lockdown on the CLI invocation (PB1, `assistant/claude/internal/chat/chat.go`).**
`buildInvocation` passes `--allowedTools <list>` where `<list>` is exactly the
20-entry `defaultMCPTools` (or its env override, `ASSISTANT_CLAUDE_MCP_TOOLS`,
still constrained to the same name family), every entry of the form
`mcp__hunter__<tool>`, never a built-in tool name (`Bash`, `Write`, `Edit`,
`Read`, `WebFetch`, `Task`, `Glob`, `Grep`, `NotebookEdit`). `--strict-mcp-config`
is always passed alongside `--mcp-config` so the CLI ignores any ambient
(e.g. user-level) MCP configuration and only ever talks to the one server this
process wrote to a per-request temp file. `--dangerously-skip-permissions` is
never emitted on any code path — confirmed by a full read of the diff, not
only by test coverage. When no MCP URL is configured or no valid grant is
supplied, the backend falls back byte-for-byte to today's argv
(`--allowedTools ""`, no `--mcp-config`): the read-only wiring is additive and
cannot itself downgrade an already-disabled deployment.

**Per-turn grant, unchanged mechanism, now also issued on the Claude path
(PB2).** `Assistant::TurnCreator` now calls `Assistant::Grants::Issuer.call`
for a Claude-backend turn exactly as it already did for the legacy gateway
path, with `resources: []` (no context attachment on this path) and
`tools: Assistant::Grants::Issuer::TOOLS` (the same catalog constant the
legacy path uses). The resulting `Assistant::TurnGrant` carries:

- **dedicated, non-wildcard read scopes** — `read_scopes:
  Assistant::TurnGrant::READ_SCOPES`, a closed, enumerated list; the model
  validates every value against that list and rejects anything else
  (`read_scopes_are_known`);
- **a call budget** — `max_calls: min(profile.tool_call_limit,
  Assistant::Config.max_tool_calls)` (hard ceiling 8);
- **a byte budget** — `max_result_bytes` (65,536) and `max_total_bytes`
  (262,144), both hard-ceilinged in `Assistant::Config::HARD_LIMITS`;
- **a 300-second TTL** — `expires_at: Assistant::Config.grant_ttl.from_now`,
  `ASSISTANT_GRANT_TTL_SECONDS` bounded to a 300-second hard ceiling; and
- **binding** to the issuing turn's `user`, `conversation`, `provider_profile`,
  and `turn` — the same four-way binding the legacy path has always used.

Only the raw token is threaded through `TurnJob` → `ClaudeCodeClient.run_turn`
→ the `/chat` request body (`turn_grant`); Postgres persists only its SHA-256
digest (`Assistant::TurnGrant.digest`), matching the existing
digest-only-persistence posture for every other Assistant credential. The raw
grant is `.clear`ed after use in `TurnCreator`'s `ensure` block, unchanged from
the legacy path.

**Transport stays on an internal-only network (PB3).** `assistant-claude`
gained a third Compose network, `assistant-claude-mcp` (`internal: true`), and
`hunter-mcp` gained that same network as a third entry in its own `networks:`
list — mirroring the existing `assistant-gateway-mcp` shape for the legacy
path. Neither `assistant-claude` nor `hunter-mcp` gained any *other* new
network, port, or `depends_on` edge. No component outside the two containers
already authorized to speak this protocol (`assistant-claude`, `hunter-mcp`)
can reach this new network segment.

**Metadata-only audit — unchanged.** A Claude-path MCP tool call reaches
`hunter-mcp` through the same machine API surface (`Api::V1::Assistant::Machine::*`)
and the same `Authorizer`/`complete_machine_response!` path the legacy gateway
path already used for Phase 2a–2c reads. This delta does not touch that
controller layer, its scope-gate, or its audit call — the event recorded for
a Claude-path tool call carries the same fields (tool name, scope, status,
byte counts; never message bodies or tool-result payloads) as a legacy-path
call already did.

**Adversarial tests.**

- PB1 argv-lockdown tests (`assistant/claude/internal/chat/chat_test.go`,
  `assistant/claude/cmd/hunter-assistant-claude/main_test.go`): every
  `AllowedTools` entry is asserted to start with `mcp__hunter__` and never to
  equal a named built-in; `--strict-mcp-config` is asserted to appear
  immediately after `--mcp-config`; the temp MCP-config file is asserted
  `0600` and removed by `cleanup()`; six distinct malformed-grant shapes
  (empty, space, tab, newline, CR, NUL, >1024 bytes) are each asserted to fall
  back to no-MCP argv, so a malformed or missing grant can never accidentally
  turn MCP on.
- The existing Phase 2a–2c runner tests (`web/test/integration/api/v1/assistant/machine/**`)
  already cover scope-denial (a grant lacking a module's read scope gets
  `403`) and secret-field rejection at the MongoSource/model layer for
  vulnerabilities. This delta does not add a new tool or scope for those
  tests to cover; it relies on their existing coverage remaining in force
  because the same controller/scope-gate code path is now reached by a second
  caller (the Claude backend) rather than only the legacy gateway.
- `web/test/services/assistant/turn_creator_test.rb` (PB2) now asserts a
  Claude-path turn issues exactly one `TurnGrant` with `Issuer::TOOLS` and
  `TurnGrant::READ_SCOPES`, and that the *raw* token (not the digest) is what
  reaches `ClaudeCodeClient.run_turn` — proven by digesting the captured value
  and comparing it to the persisted `token_digest`.

## Accepted risks / notes

**(a) `ASSISTANT_GATEWAY_MCP_TOKEN` now authenticates two internal
consumers.** `hunter-mcp` validates exactly one token digest; before this
change only `assistant-gateway` presented it, so the token was effectively a
gateway-specific credential. `assistant-claude` now presents the identical
value (`ASSISTANT_CLAUDE_MCP_TOKEN: ${ASSISTANT_GATEWAY_MCP_TOKEN}` in both
Compose files). This is a shared client→MCP secret and is **no longer
independently revocable per path**: rotating or revoking it disables MCP
access for both the legacy gateway and the Claude backend simultaneously,
where previously it could only ever have affected the gateway. This is
accepted because the token authenticates a *transport*, not a *turn* — it
proves "this process is a legitimate internal MCP client," nothing more. The
**per-turn grant remains the real per-turn authorization**: it is minted
fresh per turn, is independently scoped (its own `read_scopes`/`tools`), is
independently budgeted (its own `max_calls`/byte ceilings), expires in 300
seconds, and is bound to one user/conversation/provider_profile/turn. Revoking
a single turn's authority does not, and never did, require rotating the
shared transport token — it happens automatically at TTL expiry or budget
exhaustion. What would reverse this acceptance: a second, distinct MCP bearer
token per backend, which `hunter-mcp` would need to validate against more
than one digest — not required by anything in scope here, and not built.

**(b) `ASSISTANT_MCP_ALLOWED_ORIGINS` widened to include
`http://hunter-mcp:8080`.** The MCP server's Origin allowlist (used to reject
browser-style cross-origin requests to the internal HTTP MCP endpoint) grew a
same-origin entry to tolerate the Claude CLI's HTTP MCP client possibly
setting an `Origin` header equal to the URL it is calling. This is
defense-in-depth, not the primary gate: an empty `Origin` was already accepted
(most non-browser HTTP clients send none), and `ASSISTANT_MCP_ALLOWED_HOSTS:
hunter-mcp:8080` already independently gates on the `Host` header for every
request regardless of `Origin`. Widening the allowlist to a value that is
identical to the request's own destination does not admit any third-party
origin. What would reverse this: evidence the CLI never sets `Origin` at all
(the widening would then be unused but harmless), or evidence it sets an
attacker-influenceable `Origin` value (which would require a different fix
entirely, not a wider allowlist).

**(c) The `claude` CLI requires an interactive one-time login.** The CLI
authenticates via a Claude subscription session persisted in the
`assistant_claude_home` Docker volume (mounted at `/home/claude` in the
`assistant-claude` container), not via an API key in the environment. Until an
operator runs `docker compose exec assistant-claude claude login` once per
deployment (or per fresh volume), every Claude-backend turn fails with the
existing `ErrLoginRequired` mapping and the assistant reports "disabled
(login required)." This is an operator step, not a code gap; it is called out
explicitly in the operator runbook below rather than left implicit.

## What is retained unchanged

`hunter-mcp` remains the only path from either model-facing backend to Hunter
data and holds no provider key of its own. Neither backend gained any write,
execute, schedule, or send capability. The six-tool-family read catalog from
Phase 2a–2c, its scopes, its per-module `MongoSource` read-swallow behavior,
and its secret-field exclusions are unchanged — this delta only adds a second
caller (the Claude backend) to a controller/authorization path the legacy
gateway already exercised. The kill switch
(`Assistant::Setting#assistant_enabled?`) and the derived activation gate
(`Assistant::Config.enabled?`) still gate every browser and machine path for
both backends identically, unaffected by this delta.

## Explicitly out of scope

This delta does **not** introduce, widen, or relax:

- any Assistant context type, tool, provider feature, user role, write action,
  or execution action
- any generic network, search, shell, filesystem, credential, write, send,
  schedule, or execution tool
- any wildcard scope for a service or turn-grant identity
- the 20-tool read catalog, or any bound, limit, retention window, or
  sanitizer established by Phase 2a–2c
- the metadata-only audit contract

## Required verification evidence

1. PB1 Go test suite: argv-lockdown, malformed-grant fallback, temp-file mode
   and cleanup, `--strict-mcp-config` placement — automated, already run
   (`go test ./...` clean).
2. PB2 Rails test suite: grant issuance and raw-token threading on the Claude
   path, byte-for-byte-unchanged legacy path — automated, already run.
3. PB3 structural verification: both Compose files parse, `assistant-claude-mcp`
   is `internal: true`, both services list it, the token env var is a
   reference (not a duplicated literal) — automated (YAML/Python check), no
   Docker available in this environment.
4. Existing Phase 2a–2c scope-denial and secret-field-rejection integration
   tests continue to pass unmodified, proving the second caller does not
   bypass the authorization gate those tests exercise.
5. This document's UI disclosure element (`#hunter-assistant-capability-disclosure`
   in `web/app/views/layouts/_assistant.html.erb`) and its presence test
   (`web/test/integration/assistant_shell_test.rb`) — automated, already run.
6. A live `docker compose up --build`, `claude login`, and one real chat turn
   on the Claude provider profile that round-trips a tool call — **not yet
   run**, no Docker in this environment. See
   `docs/runbooks/assistant-claude-mcp-smoke-test.md` for the exact operator
   steps; this is a release gate for the production checklist, not an
   automated item.

Items 1–5 are automated. Item 6 is a release gate recorded in the production
checklist, which must continue to show **Not run** until an operator records
its output there.

## Approval

- Operator approval: the Path B plan
  (`docs/superpowers/plans/2026-07-29-assistant-claude-mcp-wiring.md`) that
  scoped PB1–PB3 (already implemented and committed: `7498ef5`, `2d3f2e4`,
  `280e97a`) was itself the operator-authorizing artifact for this wiring.
  This delta document — the required write-up of that change under the
  Assistant capability change rule — has **no separate operator sign-off
  stamp of its own** as of this draft.
- Threat-model delta reviewed by: **UNSET**
- Date: **UNSET**

Production stays disabled until the production checklist records independent
review evidence for this change, per the Assistant capability rule in
`AGENTS.md`. This delta being drafted does not itself satisfy that
requirement — it is the artifact the checklist review will point to.
