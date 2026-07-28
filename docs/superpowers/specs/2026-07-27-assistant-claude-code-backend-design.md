# Assistant Claude Code backend — design (2026-07-27)

Status: **APPROVED (design)** — pending written-spec review.

## Motivation

The current Assistant chat runs turns through a hand-rolled provider gateway
(`assistant/gateway`) that reimplements the agentic loop against the Anthropic
Messages API: multi-round tool calls, thinking-block handling, a strict
structured-output envelope, and per-turn grants. That loop is fragile — it took
repeated fixes to make plain chat reliable, and draft turns still fail
intermittently — and it is billed pay-as-you-go against an API key.

The official **Claude Code CLI** already implements that agentic loop correctly
and robustly, connects to MCP natively, and can run on a personal Claude
subscription. This design replaces the gateway-backed chat with a small service
that runs the official Claude Code CLI, keeping Hunter's existing chat UI, API,
and conversation model.

## Constraints (load-bearing)

1. **Personal, single-user use of the official CLI only.** This design relies on
   Anthropic's carve-out permitting the *official* Claude Code CLI for scripted
   personal use on a subscription. It is **not** for serving other end users,
   always-on-as-a-product, or business deployments — those require an API key
   under the Commercial Terms. The token is never extracted; only the official
   `claude` binary makes provider calls. This constraint is recorded here and
   must not be widened without revisiting the terms.
2. **The login persists independently of Hunter's chat state.** The operator runs
   `claude login` once; the credential lives on a persistent volume in the
   `assistant-claude` container and auto-refreshes. Disabling ("killing") the
   chat, restarting the service, rebuilding the image, and `docker compose
   down`/`up` all preserve the login. Only destroying the volume (`down -v` or
   deleting it) forces a re-login.
3. **Capability rule (`AGENTS.md`).** Claude Code is a general agent whose native
   tools (bash, filesystem, web) are exactly the generic execution tools the rule
   prohibits. Phase 1 therefore runs Claude Code with **no tools at all** — the
   smallest possible surface. The MCP read tools (Phase 2) get their own
   threat-model delta.

## Scope

**Phase 1 (this spec): minimal chat.** Plain conversational chat, powered by the
official Claude Code CLI on the operator's subscription, reusing Hunter's chat
panel, `/api/v1/assistant/{bootstrap,conversations,turns}` API, and
`Conversation`/`Message`/`Turn` models. No MCP, no tools, no structured
envelope, no drafting/validation/confirmed-save.

**Phase 2 (future, separate spec): read-only MCP tools.** Wire Claude Code to
`hunter-mcp`'s read tools (context/policy/example lookups) with a
per-conversation grant. Requires its own capability-rule delta.

**Explicitly out of scope for now:** drafting, validation, confirmed-save, the
structured envelope, and any write/execute tool. The existing code for these is
kept in the tree, disconnected, for later reuse.

## Architecture (Phase 1)

Three parts. Everything else in the current Assistant is kept but disconnected.

### 1. `assistant-claude` service (new)

A hardened, internal-only container that runs the official Claude Code CLI and
holds **only** the subscription credential.

- **Runtime:** the official `claude` CLI (Node) plus a thin HTTP wrapper. The
  wrapper is the only listener; it shells out to `claude` and never exposes the
  credential.
- **Endpoint:** `POST /chat`, bearer-authenticated with a dedicated ingress
  token (`ASSISTANT_CLAUDE_INGRESS_TOKEN`), same pattern as the gateway.
  - Request: `{ "prompt": <string>, "session_id": <string|null> }`.
  - Behaviour: run `claude -p <prompt> --output-format json` — with
    `--resume <session_id>` when one is supplied — under a tool-denying
    configuration. Parse the JSON result for the assistant text and the session
    id.
  - Response: `{ "session_id": <string>, "reply": <string> }`, or a structured
    error `{ "error": { "code": <stable-code> } }`.
- **Tool configuration:** all built-in tools disabled (no bash, file, or web);
  no MCP servers configured in Phase 1. The assistant behaves as a pure
  text chat.
- **Credential + session persistence:** the Claude Code home/config directory
  (login credential *and* session store) is mounted on a **named volume**
  (`assistant_claude_home`). One-time interactive `claude login`
  (`docker compose exec assistant-claude claude login`). Auto-refresh keeps it
  valid; the volume decouples it from every Hunter/chat lifecycle event.
- **Network:** reachable from `web` only (a dedicated internal network); a single
  non-internal egress network for `api.anthropic.com` / the Claude Code auth
  host. No datastore or execution-surface reachability.
- **Hardening:** non-root, read-only rootfs with the credential volume and a
  tmpfs as the only writable paths, `cap_drop: ALL`, `no-new-privileges`,
  seccomp, mem/pids/cpu limits — consistent with the other assistant services.
- **Rebuild-on-up:** `pull_policy: build` like the other dev services, so a
  source change is never served stale. The credential volume is unaffected by
  rebuilds.

### 2. `Assistant::ClaudeCodeClient` (new, Rails)

Replaces `Assistant::GatewayClient` at the dispatch seam. Single-attempt HTTP
POST to `ASSISTANT_CLAUDE_URL` (`http://assistant-claude:<port>`), carrying the
ingress token, the conversation's stored `session_id`, and the user prompt.

- Returns the **same ordered event array shape the gateway produced** — an
  `assistant_message` event carrying `{ body: reply }` followed by a `completed`
  event — so `Assistant::EventIngestor`, the assistant `Message`, and the chat UI
  all work unchanged.
- Never lets a transport exception escape: every failure maps to a stable
  `claude_*` error code returned as an `error` event (mirrors `GatewayClient`'s
  contract), so a failed turn is recorded, never stranded.

### 3. Reuse seam

- A single synthetic **"Claude Code" provider profile** (a marker row, not an API
  key) satisfies the existing `Conversation → provider_profile` requirement and
  appears in the bootstrap/dropdown. The dispatch routes any conversation bound
  to it to `ClaudeCodeClient`.
- The `Conversation` gains a nullable `claude_session_id`. The first turn stores
  the session id returned by the service; later turns pass it back for
  `--resume`.
- Turn creation reuses `TurnCreator`/`Turn` for status, rate-limiting, and audit,
  but the dispatch branch that built a gateway envelope + provider grant is
  bypassed for this profile — Phase 1 needs neither (no tools, no MCP).

### No activation/on-off — always available, fails loudly

There is **no enable/disable state** for the Claude Code chat. It is always
present in the UI. The API-key-derived activation (`Assistant::Activation` /
`Config.enabled?`) does **not** gate this path — the dispatch does not check an
"enabled" flag at all. If the backend is not ready, the turn simply **fails with
a clear, specific error** (see Errors) rather than the feature silently showing
"disabled". The Settings kill switch is not used to gate this path. In short:
if it doesn't work, the user is told exactly why, on the turn they tried.

## The disconnect (first implementation step)

Disconnect the current gateway-backed chat from use while keeping all code — no
on/off flag involved:

1. **Stop routing turns to the gateway** — remove the provider API keys from
   `.env` and the API-key provider profiles, so no conversation binds to an
   API-backed profile and nothing reaches the gateway. The gateway path becomes
   dead code (present, unreachable). The chat panel stays visible; there is no
   "disabled" state.
2. **`assistant-gateway` and `assistant-validator` become dormant** — kept in the
   compose files but moved behind a compose profile so a default `up` no longer
   starts them. `hunter-mcp` is left in place for Phase 2.
3. **No code is deleted.** The gateway, validator, provider adapters,
   turn-envelope/grant machinery, drafting/validation/confirmed-save controllers,
   and `GatewayClient` all remain in the tree.

Between this step and the Claude Code backend landing, opening the chat and
sending a message returns a clear "assistant backend not configured" error — the
always-on, fail-loudly behaviour, not a silent disable. The step is fully
reversible: restoring the keys/profiles and the compose profile brings the old
path back exactly.

## Data flow (one Phase 1 turn)

1. User sends a message → `POST /api/v1/assistant/conversations/:id/turns`
   (unchanged UI/API).
2. `TurnCreator` creates the `Turn`; the dispatch seam sees a "Claude Code"
   profile and calls `ClaudeCodeClient` with the conversation's
   `claude_session_id` and the message body.
3. `ClaudeCodeClient` → `POST /chat` on `assistant-claude` → `claude -p …`
   (resumed if a session exists) → `{ session_id, reply }`.
4. On the first turn, `claude_session_id` is stored on the conversation.
   `ClaudeCodeClient` returns `[assistant_message{body: reply}, completed]`;
   `EventIngestor` writes the assistant `Message` and marks the turn completed.
5. The UI renders the reply through the existing turn/event path.

## Errors

Because the chat is always on with no enable flag, **every failure mode is a
specific, self-explanatory code** shown on the turn the user tried — that is what
replaces an activation state. Stable `claude_*` codes, surfaced as the existing
"Turn failed: <code>" UI:

- `claude_not_configured` — the Claude Code backend isn't wired up yet
  (`ASSISTANT_CLAUDE_URL`/ingress token unset, or no Claude Code profile). Expected
  during the window between the disconnect and the backend landing.
- `claude_login_required` — no/expired credential in the container (operator must
  `claude login`).
- `claude_timeout` — the CLI exceeded the turn deadline.
- `claude_unreachable` / `claude_dns_failure` / `claude_connection_refused` —
  transport faults reaching `assistant-claude` (mirrors the gateway's
  distinctions).
- `claude_malformed_response` — the CLI's JSON could not be parsed.
- `claude_error` — a non-zero CLI exit with a recognised failure.

The service never returns the credential or raw token in any error.

## Security & capability-rule delta

- **Smallest surface.** Phase 1 Claude Code runs with **no tools** — no bash,
  filesystem, web, or MCP. It can only produce text. This is a strictly smaller
  execution surface than the current gateway (which drives 6 MCP tools).
- **Credential isolation.** Only `assistant-claude` holds the subscription login,
  on its own volume; `web` and every other service never see it. `web` reaches
  the service solely through the bearer-authenticated `/chat` route.
- **Audit stays metadata-only.** Turn audit records the same metadata as today
  (correlation id, conversation/turn/user ids, outcome) — never prompt/response
  bodies or the credential.
- **Network isolation.** `assistant-claude` shares no network with datastores or
  execution surfaces; its only non-internal network is provider egress.
- The Phase 2 MCP read-tool surface is a separate capability change requiring its
  own approved threat-model delta before implementation.

## Testing (no live subscription in CI)

- **`ClaudeCodeClient`** — unit-tested against a stub HTTP server: success maps to
  `[assistant_message, completed]`; each error maps to its stable code; a dropped
  connection never raises.
- **`assistant-claude` wrapper** — tested against a **fake `claude` binary** on
  `PATH` that emits canned JSON (success, malformed, non-zero exit); asserts the
  request→CLI mapping, `--resume` threading, tool-denying invocation, and that
  the credential is never echoed.
- **Rails turn flow** — the existing turn/ingestion tests run with a stubbed
  `ClaudeCodeClient`, asserting the reply is stored as an assistant message and
  the turn completes.
- **Compose contract** — `assistant-claude` asserted internal-only, non-root,
  read-only, seccomp'd, credential volume present, egress-only, and profile
  placement of the now-dormant gateway/validator.

## Phasing

- **Phase 1 (this spec):** disconnect current chat → `assistant-claude` service →
  `ClaudeCodeClient` + reuse seam → working chat on the subscription.
- **Phase 2 (separate spec + delta):** Claude Code → `hunter-mcp` read tools with
  a per-conversation grant.
- **Later / maybe:** re-introduce drafting/validation/confirmed-save on top of the
  Claude Code path if wanted.

## Open questions / risks

- **Session store growth** on the credential/home volume over time — needs a
  retention/cleanup story (Phase 1 can defer; note it).
- **Interactive login in a container** — `claude login` is a browser OAuth flow;
  the plan must document the one-time setup (e.g. `--no-browser` device flow).
- **CLI/version drift** — the official CLI updates; pin a version in the image and
  bump deliberately.
- **Latency** — a `claude -p` invocation per turn; acceptable for personal chat,
  measured during implementation.

## Required verification evidence

1. Disconnect verified: no conversation routes to the gateway (dead code, still
   present and compiling); the chat stays visible and, with no backend configured,
   a turn fails with `claude_not_configured`; reversible.
2. `assistant-claude` boots, `claude login` persists across service restart and
   image rebuild, and is only lost on volume deletion.
3. A real chat turn completes end-to-end on the subscription (operator-run, since
   it needs the login), returning an assistant message.
4. All automated suites above pass with no live subscription.
5. Credential never appears in logs, audit rows, API responses, or error bodies.
