# Assistant Direct Provider Selection — Design & Threat-Model Delta

**Status:** APPROVED FOR IMPLEMENTATION

**Implementation status (2026-08-15):** Tasks 1–6 are implemented in commits
`6e29293` through `53b5be8`. The local implementation evidence is recorded
below; production remains disabled pending the candidate-specific container,
login, browser, canary, and rollback evidence in the production checklist.

**Date:** 2026-08-13

**Approval record:** The operator requested a logo-only OpenAI/Anthropic chooser,
one-click conversation creation, Codex for OpenAI, Claude Code for Anthropic,
and retirement of token-backed provider selection. During design review the
operator explicitly approved isolated subscription-backed runners, read-only
legacy history, the closed backend API, a collapsible history rail, and compact
copyable fenced code blocks, then instructed development to begin while they
were unavailable. This approves specification, planning, implementation,
testing, and commits. It does not by itself complete the independent Assistant
production checklist.

**2026-08-15 amendment:** The exact Codex/Hunter tool boundary in this document
is superseded by the separately approved
[`2026-08-15-assistant-codex-mcp-boundary-design.md`](2026-08-15-assistant-codex-mcp-boundary-design.md).
Codex-owned internal tools may remain only under that delta's exact pin and
isolation; every Hunter capability remains MCP-only.

**2026-08-19 amendment:** The exact Hunter `CHAT_TOOLS` catalog and this
document's old no-run/no-send Hunter capability statements are superseded by
[`2026-08-19-assistant-mcp-administrator-proxy-design.md`](2026-08-19-assistant-mcp-administrator-proxy-design.md).
The direct-provider binding, credential isolation, hardened runner, exact
Codex-owned built-in pin, and MCP-only Hunter access requirements remain in
force.

## Goal

Make provider choice direct and understandable: an OpenAI logo starts a Codex
conversation and an Anthropic logo starts a Claude Code conversation. Provider
API-key profiles are legacy and cannot create or continue chats. The message
workspace remains the visual focus through a collapsible history rail and
compact, copyable fenced code blocks.

## Terminology and non-goals

“Token-backed” in this design means provider API-key profiles dispatched through
the legacy `assistant-gateway`. It does not mean Hunter's internal ingress
bearers, service identity, or per-turn grants; those remain narrow security
boundaries and are never provider billing credentials.

This change does not add a third provider, arbitrary model selection, arbitrary
CLI flags, generic tools, a generic runner, profile image upload, conversation
provider switching, legacy transcript migration, or deletion of legacy rows.

## Selected architecture

### Two isolated subscription-backed runners

- `assistant-claude` remains the Anthropic backend and continues to run the
  official Claude Code CLI with its existing persistent login volume.
- A new `assistant-codex` service runs a pinned official Codex CLI with ChatGPT
  authentication cached in its own persistent `CODEX_HOME` volume.
- Rails reaches each runner over a separate internal-only network and dedicated
  authenticated `/chat` ingress. Each runner has only provider egress plus the
  reviewed Hunter MCP route; neither joins datastore, runner, Docker, or Control
  Center execution networks.
- Credentials never cross runners. Rails never receives either subscription
  credential, and neither runner receives the other's ingress token or home
  volume.

Codex uses the official non-interactive contract: `codex exec --json` for a new
thread and `codex exec resume <thread_id> --json` for later turns. JSONL is
parsed for the thread identifier, final agent message, terminal success, and a
closed set of stable failures. ChatGPT login is forced in Codex configuration;
no `OPENAI_API_KEY`, `CODEX_API_KEY`, or API-key login path is accepted.

### Closed backend binding

New conversation creation accepts exactly one backend slug:

```json
{"backend":"codex"}
```

or:

```json
{"backend":"claude_code"}
```

`Assistant::ChatBackend` is a closed resolver for those two values. It maps each
slug to exactly one enabled, reviewed synthetic profile row and rejects every
other value. The browser never submits a profile ID. The existing
`provider_profile_id` association remains as an internal compatibility seam for
audits, turns, foreign keys, and old transcripts.

Each conversation is pinned permanently. Claude session continuity remains in
`claude_session_id`; Codex continuity uses a separate nullable
`codex_thread_id`. Neither identifier may be accepted from the browser or moved
between backends.

### Legacy profiles and history

The `openai_primary` and `anthropic_primary` catalog rows, profile data, gateway
code, and dormant compose services remain available for rollback, but are
unreachable from current chat behavior:

- bootstrap returns only the two direct chat backends;
- the new-conversation endpoint rejects `provider_profile_id` and unknown
  backend slugs;
- `TurnCreator` rejects a new turn on a legacy conversation with
  `legacy_provider_retired` before a grant or job is created;
- provider-profile creation and editing disappear from Settings;
- old conversations remain owned, visible, readable, renameable, reorderable,
  and deletable, but their composer is disabled and marked **Legacy**.

No migration rewrites old conversations to a new backend. Doing so would break
the immutable provider/session boundary and misrepresent transcript provenance.

## User experience

### One-click chooser

The start screen contains two equal brand controls: the OpenAI logo and the
Anthropic logo. There is no dropdown, model string, or separate Start button.
Visible content is logo-only; each control still has an accessible name,
keyboard operation, focus treatment, and a short native tooltip.

Activating a logo immediately POSTs the closed backend slug. Both choices lock
while the request is active so a double click cannot create duplicate chats.
The selected logo shows a bounded loading state. Success opens the new chat and
focuses the composer; failure restores the chooser and reports a stable,
actionable error.

The chosen provider logo becomes the Assistant avatar and conversation header
identity for that chat. The human user's independent placeholder avatar remains
unchanged. A legacy transcript uses a neutral archive avatar and label rather
than pretending it ran on a direct backend.

### History focus mode

The history sidebar gains an explicit Collapse control. On desktop it collapses
to a narrow rail containing only New Chat and Expand controls, so the message
workspace receives the available width. On mobile, history is a dismissible
drawer rather than a persistent width reservation.

The desktop collapsed preference is stored only as the closed boolean shape
`{"collapsed":true|false}` under `hunter:assistant-history-rail:v1`. Missing,
unavailable, malformed, extra-key, or non-boolean storage falls back to
expanded. No title, conversation ID, message, provider identity, or other user
data is stored. Collapse never changes server state or history loading.

### Compact fenced code blocks

Every fenced Markdown `pre > code` block receives a small inert toolbar after
the Markdown fragment has been sanitized and mounted:

- a language label when the parser emitted a recognized language class;
- a **Compact/Expand** toggle;
- a **Copy code** button.

Long blocks begin compact; short blocks remain fully expanded. Compact state
limits visual height and exposes an overflow cue without altering or truncating
the underlying text node. Copy always writes the complete plain code text,
never generated HTML. Compact state is per rendered block and is not persisted.
Inline code receives no toolbar.

Toolbar construction uses `createElement`, `textContent`, and event listeners
after sanitization. It never reparses or mutates sanitized HTML strings and
never adds content originating outside the already-sanitized code text. This is
the sole permitted post-sanitize DOM decoration.

## Availability and errors

Provider API-key availability no longer participates in chat activation. The
administrator Assistant kill switch remains authoritative for new direct chats
and turns. Runner health/login is evaluated per request and fails loudly rather
than hiding a logo.

Stable Codex errors are namespaced and contain no provider output:

- `codex_not_configured`
- `codex_login_required`
- `codex_timeout`
- `codex_unreachable`
- `codex_dns_failure`
- `codex_connection_refused`
- `codex_malformed_response`
- `codex_usage_limit`
- `codex_error`
- `codex_returned_no_events`

Existing `claude_*` errors remain. The UI maps login/configuration failures to
operator guidance and leaves unknown codes generic. Raw CLI stderr, JSONL,
credentials, prompts, replies, commands, and tool arguments never enter API
errors or audit metadata.

## Threat-model delta: Codex provider and execution path

This is a new Assistant provider feature and an execution path, so this section
is the required approved delta under `AGENTS.md`.

### Dedicated schema and authorization

- `Assistant::ChatBackend` accepts exactly `codex` or `claude_code`; there is no
  provider/model/URL/command/flag field and no wildcard fallback.
- `POST /api/v1/assistant/conversations` remains same-origin session-only,
  Assistant-administrator-only, CSRF-protected, and rejects bearer API auth.
- Every turn remains owner-bound, rate-limited, provider-profile-bound, and
  associated with a per-turn grant.
- Codex receives only the exact `CHAT_TOOLS` grant and the existing dedicated
  non-wildcard read/create/edit scopes. Turning off Control Center writes strips
  the four authoring tools and matching scopes before dispatch.
- The Assistant kill switch and existing independent
  `control_center_write_enabled` revocation continue to apply immediately.

### Codex-owned tools and the Hunter MCP boundary

The Codex process continues to disable shell/unified execution, web search,
browser/computer use, apps/connectors, plugins, skills, image generation,
multi-agent, and permission-request tooling. User/project config and execpolicy
rules are ignored. The working directory is empty and immutable, with no Hunter
checkout, host bind, Docker socket, datastore credential, or unrelated secret.

The approved 2026-08-15 delta permits only the exact Codex-owned built-ins
captured for the pinned CLI. Those built-ins receive no direct Hunter or host
capability. Every Hunter read or effect, including a future API-backed feature,
must pass through the single authenticated `hunter` MCP server, exact reviewed
catalog, per-turn grant, dedicated non-wildcard scopes, and existing policies.

CI runs the real pinned binary against local fake provider and MCP endpoints. It
fails on any Codex-owned tool drift, another MCP source, missing or extra Hunter
tool, Hunter schema drift, or a successful write to the immutable workspace.
The wrapper also refuses to start when its hardened configuration is missing or
invalid.

### Human approval and effects

Clicking a provider logo approves only creation of an empty local conversation;
it does not run a model. Submitting a message is the explicit human action that
starts one Codex or Claude turn. Cancel remains available for an active turn.

Hunter reads are bounded by the existing grant and policies. The only
approval-free writes are the already approved Whiterabbit template/Ansible
playbook create and explicit edit exceptions in `AGENTS.md`: exact dedicated
tools/scopes, mandatory fail-closed validators, create-only `Model.new`, edit by
ID plus `expected_lock_version`, attribution, audit, and revocation toggle.
There is no delete, run, send, schedule, shell, filesystem, credential, or
generic network path. Any change to this set requires another delta.

### Credential and network isolation

- Codex authentication is stored only in `assistant_codex_home`; Claude
  authentication remains only in `assistant_claude_home`.
- Both homes are treated as secrets, mounted only into their matching non-root
  service, never logged, copied into images, or exposed to Rails.
- Runner ingress uses a dedicated constant-time-compared bearer and exact Host
  allowlist before reading the body or spawning a CLI process.
- Request bodies, responses, and JSONL are byte-bounded; timeouts and process
  counts are bounded; one turn produces at most one CLI invocation.
- Each service uses `cap_drop: ALL`, `no-new-privileges`, seccomp, tmpfs for
  per-turn files, resource limits, and no published host port.

### Audit and disclosure

Existing `turn.created`, dispatch, tool, authoring, completion, cancellation,
and failure audits remain metadata-only. They include IDs, backend/model marker,
operation, stable outcome, and stable reason where applicable. They never store
prompt/reply bodies, code contents, session/thread IDs, credentials, raw errors,
tool arguments, or copied text.

The chooser and conversation header disclose the selected provider through its
logo and accessible name. Settings explain subscription login, direct CLI use,
retention caveats, and that API-key profiles are retired. Legacy transcripts
are visibly marked and non-runnable.

## Abuse cases and stable outcomes

- Unknown/missing/extra conversation-create key: `400 bad_request`, no row.
- Unsupported backend or missing direct profile: `404 not_found`, no row.
- Disabled/review-incomplete direct profile: `422 validation_failed`, no row.
- Legacy profile ID posted directly: `400 bad_request`, no row.
- Turn posted to legacy transcript: `409 legacy_provider_retired`, no grant/job.
- Foreign conversation: `404`, with no ownership disclosure.
- Assistant kill switch off: `503 assistant_disabled`, no row/turn/job.
- Double logo activation: one browser request; server constraints and UI lock
  prevent accidental duplicate creation.
- Cross-backend session identifier: ignored by routing and never sent to the
  other service; model validation rejects an impossible persisted combination.
- Codex exposes any built-in outside the exact pinned set or gains a direct
  Hunter/host path: contract or isolation checks fail CI and production review.
- Codex invokes an ungranted Hunter tool or scope: MCP returns the existing
  stable authorization failure; no effect occurs.
- MCP/runner/login/provider timeout or malformed response: stable namespaced
  failed turn, grant revoked, no automatic retry and no duplicate spend.
- CLI emits secrets/raw stderr: wrapper discards it and returns a closed code.
- Malicious fenced-code language/content: language is normalized to a closed
  display token, code remains text, clipboard copies text only, and toolbar DOM
  is application-created.
- Malformed history preference: expanded fallback; no server write.
- Clipboard unavailable/denied: polite failure status, no mutation.

## Component boundaries

- `Assistant::ChatBackend`: closed slug/profile resolution and legacy predicate.
- `Assistant::ProviderProfile`: direct-backend helpers and impossible-state
  validation; legacy catalog entries remain data-compatible.
- `Assistant::Conversation`: separate Codex/Claude session fields and immutable
  backend binding.
- `Assistant::TurnCreator` / `TurnJob`: backend-neutral direct dispatch with
  shared grant issuance, legacy rejection, and stable recovery.
- `Assistant::CodexClient`: bounded Rails HTTP client returning the existing
  event array contract.
- `assistant/codex`: authenticated wrapper, hardened CLI argv/config, JSONL
  parsing, resume handling, stable errors, and health endpoint.
- Compose and seccomp: credential volume plus isolated ingress, MCP, and egress
  networks.
- Bootstrap/conversation API: backend descriptors and closed create request.
- `assistant_provider_picker.js`: pure descriptor filtering/selection state.
- `assistant_history_rail.js`: closed local preference parsing.
- `assistant_markdown.js` / `assistant_ui.js`: sanitized code-block decoration,
  compaction, and exact-text clipboard behavior.
- Stimulus/template/CSS: immediate logo creation, loading lock, provider avatar,
  legacy disabled state, responsive history rail/drawer, and code controls.

## Testing and production evidence

Implementation is test-driven. Required coverage includes:

- closed backend resolution and exact request schemas;
- no legacy profile selection, conversation creation, grant, job, or dispatch;
- legacy transcript read/history management with disabled composer;
- Codex client success, session resume, every stable transport/provider error,
  byte/time bounds, and no sensitive error propagation;
- Go wrapper argv/env construction, ChatGPT-only authentication, JSONL parsing,
  cancellation, malformed/oversized output, and secret redaction;
- captured real-Codex outbound definitions exactly equal the approved pinned
  built-ins, while the sole deferred `hunter` source exactly equals the reviewed
  MCP catalog and a real patch attempt cannot mutate the workspace;
- compose isolation, hardening, exact mounts/networks, no API-key variables,
  and persistent login behavior;
- one-click mouse/keyboard creation, in-flight deduplication, provider avatar,
  error recovery, and focus placement;
- history rail storage validation, desktop collapse, mobile drawer, and message
  width behavior;
- long/short/inline code rendering, compact/expand, exact full-text copy,
  language normalization, sanitizer adversarial fixtures, and clipboard failure;
- settings disclosure and removal of provider-profile authoring controls;
- focused Rails/JavaScript/Go suites, full Rails and JS suites, Tailwind build,
  Zeitwerk, dependency/security checks, Docker builds, and authenticated live
  smoke through gateway port 5000.

### Chat focus controls evidence (2026-08-13)

The chat-focus subsystem is implemented and verified independently of the
remaining direct-provider work. Browser-only history preference coverage checks
the exact versioned storage key, both boolean values, and unavailable storage;
the shell test checks the labelled `aria-controls` relationship. Sanitized
fenced code is decorated after DOMPurify processing, leaves inline code alone,
copies the complete source text, and reports clipboard rejection without an
uncaught error. Verification passed with 112 JavaScript tests, 8 shell-markup
runs and 60 assertions, the Tailwind CSS v4.3.1 build, and Rails importmap
resolution for the focus-control modules.

This evidence applies only to the history-focus and compact-code controls. It
does not mark direct-provider selection complete or change production status.

### Direct-provider implementation evidence (2026-08-15)

The closed backend domain, legacy retirement, direct Rails dispatch, hardened
Codex wrapper, exact real-binary MCP boundary, Compose isolation contracts,
one-click chooser, provider identity, and Settings retirement are implemented.
The final implementation commits are `795ffd1`, `b69b7a7`, `a788ed4`,
`2fbf725`, `788ed9c`, `e98ea4d`, and `53b5be8`.

Local verification passed 127 JavaScript tests; the Codex, Claude, MCP,
gateway, and validator Go race suites; both mandatory real Codex 0.144.4
boundary tests; Zeitwerk; the Tailwind CSS v4.3.1 build; `bundle-audit`; and
27 direct-provider release/Compose gate runs with 1,056 assertions. The release
workflow and live security scripts now enumerate both direct runner images.
The production-confidence Brakeman gate passed with no warnings; its broader
default scan reports one pre-existing medium `permit!` warning in the
intentionally schemaless vulnerability document endpoint. A full Rails run
reached 1,361 runs and 7,166 assertions before one documentation assertion
failed; that assertion was corrected and its focused suite passed, but
PostgreSQL then became unavailable before a fresh full run.

This is implementation evidence, not release approval. This host has no Docker
or compatible container runtime, so image builds, resolved Compose inspection,
live subscription logins, authenticated browser turns, canary review, and the
rollback drill remain operator-only evidence pending against a fixed candidate.
The Assistant must remain disabled until those results and an independent
enable decision are recorded in the production checklist.

Production remains disabled until the Assistant production checklist records:
the pinned Codex version and image digest, tool-schema capture, login persistence,
network inspection, credential non-disclosure, real Codex and Claude turns,
legacy rejection, stable failure demonstrations, and all automated suites.

## Considered approaches

### A. Separate direct CLI services — selected

This matches the user's subscription-backed intent, keeps credentials and
failures independently revocable, and preserves the existing Claude path while
adding Codex at the same seam.

### B. One shared multi-provider CLI broker — rejected

It reduces service count but co-locates credentials, expands one compromise
across providers, and encourages a generic command/provider schema prohibited by
the capability rule.

### C. Rebrand the token gateway — rejected

It is the smallest UI change but continues provider API-key billing and arbitrary
reviewed profiles behind misleading logos, directly contradicting the request.

## Authoritative Codex behavior used by this design

- OpenAI documents ChatGPT subscription login, persistent CLI authentication,
  forced login method, and headless device authentication:
  <https://learn.chatgpt.com/docs/auth>
- OpenAI documents `codex exec`, JSONL events, explicit sandboxing, and session
  resume by ID:
  <https://learn.chatgpt.com/docs/non-interactive-mode>
- OpenAI documents permission and configuration controls used for defense in
  depth:
  <https://learn.chatgpt.com/docs/permissions>
