# Assistant Conversation Workspace — Design & Threat-Model Delta

**Status:** COMPLETE — APPROVED AND VERIFIED

**Date:** 2026-08-13

**Approval record:** The operator explicitly requested conversation rename,
delete, and drag ordering; safe Markdown; user and Assistant profile bubbles;
stronger chat borders; panel resizing; text scaling; per-message copy controls;
and Hunter-native colors. The operator granted free hands, instructed the agent
to structure/spec/plan the work and then begin development, and said they would
be unavailable. That instruction approves the selected design and authorizes
specification, planning, implementation, testing, and commits without another
interactive review gate. It does not complete the independent production
security checklist.

## Goal

Turn the floating Assistant into a coherent conversation workspace. History is
manageable with pointer, keyboard, and context-menu interactions; messages are
readable Markdown with a narrow XSS boundary; identity, borders, sizing, font
controls, copy actions, and colors feel native to Hunter.

## Current state and confirmed gaps

- Conversations are always ordered by `updated_at DESC`. The data model has no
  user-defined history position and the API supports only list, show, create,
  and delete.
- Conversation titles render as inert text, but there is no rename or reorder
  action and deletion is available only from the current-chat toolbar without a
  confirmation step.
- Message bodies render with `textContent` inside `pre`/`p`; this is XSS-safe
  but does not support Markdown.
- Messages identify the sender only with a small text label. There is no visual
  avatar slot for future profile images and no message copy control.
- The panel already has a tested top-left pointer and keyboard resize control,
  but its affordance is visually quiet.
- Assistant surfaces use cyan accents that conflict with Hunter's neutral
  black, white, and zinc visual language.
- Chat text is fixed-size and cannot be changed independently of the browser.

## Selected product behavior

### Conversation history

Every history row has two entry points to the same action set:

1. Right-clicking the title opens a custom context menu at the pointer.
2. A visible overflow button opens the same menu and supports keyboard use.

The menu contains **Rename**, **Move up**, **Move down**, and **Delete**.
`Shift+F10` and the Context Menu key open it for the focused row. Escape and an
outside click close it. Move actions are disabled at the list boundaries.

Rows are draggable with native HTML drag and drop on desktop. A drop reorders
the complete owned list optimistically, persists it, and restores the server
order if persistence fails. Move up/down provides the same behavior for
keyboard and assistive-technology users; dragging is not the only path.

Rename opens a labelled modal with the existing title selected. Save is an
explicit human action. Titles are stripped, required, limited to 200
characters, and always displayed as text. Delete requires an explicit browser
confirmation that names the conversation and states that Hunter transcript
content is hard-deleted while provider or backup copies may remain. Both the
history menu and current-chat toolbar use the same delete path.

### Ordering semantics

`assistant_conversations.history_position` is a nullable bigint. History is
ordered by `history_position ASC NULLS LAST`, then `updated_at DESC`, then ID
descending. Existing rows therefore retain their current order before a user
first reorders them. A new conversation takes a position immediately before
the user's current minimum while holding the user row lock, so new chats appear
at the top without disturbing the saved relative order.

Reorder accepts the complete ordered list of the current user's conversation
IDs. The server holds the user and conversation locks, rejects duplicates,
foreign IDs, omissions, stale lists, non-integers, or more than 1,000 IDs, then
assigns dense positions `0..n-1` in one transaction. Reorder never changes a
conversation's `updated_at`, title, messages, provider binding, retention, or
turn state.

### Markdown rendering

Both user and Assistant bodies support GitHub-flavored Markdown. The browser
uses locally vendored, version-pinned **Marked 18.0.9** and **DOMPurify 3.4.13**,
verified as the current upstream releases on 2026-08-13. No CDN or runtime npm
request is allowed.

The rendering pipeline is deliberately one-way and effect-free:

1. Replace control characters with the existing visible replacement marker.
2. Parse Markdown synchronously with Marked (`gfm: true`, `breaks: true`).
3. A custom Marked HTML renderer emits raw HTML tokens as escaped text, so
   transcript HTML is never treated as authored markup.
4. Sanitize the parser output with DOMPurify and append the returned
   `DocumentFragment` directly. No application code writes parser output with
   `innerHTML` and no library modifies the fragment after sanitization.
5. If DOMPurify reports an unsupported browser or parsing/sanitizing throws,
   render the original body with `textContent` instead.

The sanitizer allowlist is closed:

- Tags: `p`, `br`, `strong`, `em`, `del`, `blockquote`, `ul`, `ol`, `li`,
  `pre`, `code`, `h1`–`h6`, `a`, `hr`, `table`, `thead`, `tbody`, `tr`, `th`,
  and `td`.
- Attributes: `href` and `title` only.
- ARIA attributes, data attributes, custom elements, styles, classes, IDs,
  images, media, SVG, MathML, forms, iframes, scripts, and event handlers are
  not allowed.
- Links stay in the current tab and receive no post-sanitize attributes.
  DOMPurify's protocol checks remain authoritative.

Marked is a parser, not a sanitizer; DOMPurify is the mandatory final boundary.
DOMPurify's upstream guidance warns that modifying sanitized markup afterward
can invalidate protection, so this design forbids post-sanitize mutation.

### Message presentation and controls

Each message is a flex row with a circular avatar slot and a bordered message
card. Assistant rows show a Hunter `H` placeholder before the card; user rows
show a neutral person placeholder after the card. The stable avatar containers
can later receive image URLs without changing message layout. This pass does
not add profile-image storage, upload, URL fetching, or a new identity field.

Every message card has a sender label and **Copy message** button. Copy writes
the original plain Markdown body—not generated HTML—to the Clipboard API. A
polite status reports success or failure. Copying causes no Hunter API call,
audit event, or server-side write.

Message text scale has four bounded values: 87.5%, 100%, 112.5%, and 125%.
Decrease and increase buttons expose their purpose and current boundary through
accessible labels and disabled states. The selected index is stored in the
closed numeric local-storage shape `{ "index": integer }` under
`hunter:assistant-font-scale:v1`. Missing, unavailable, malformed, extra-key,
or out-of-range data falls back to 100%. No message or identity data is stored.

### Panel and Hunter visual language

The existing anchored top-left pointer/keyboard resizing remains the sizing
mechanism. The handle becomes more visible, receives a short visible tooltip,
and the outer panel and message region receive stronger neutral borders. Mobile
remains full-screen and non-resizable.

Assistant-specific cyan styling is removed. Primary actions use Hunter's
black/white inverse treatment; selected and hover states use zinc surfaces;
focus rings use zinc/white contrast; amber remains warning/status and rose
remains destructive/error. No global brand token is changed because other
Hunter modules may rely on it.

## Considered approaches

### A. Server-backed organization plus browser Markdown boundary — selected

Persist a per-user order in PostgreSQL and add two closed session endpoints.
Keep transcript bodies raw in the API and isolate parsing/sanitizing in a small
browser module. This keeps order consistent across devices, follows the current
Rails/Stimulus architecture, and creates auditable server boundaries for the
new writes.

### B. Browser-only names/order in local storage — rejected

This avoids migrations and write routes but diverges across devices, loses
changes with site data, can show stale titles, and creates a second source of
truth for server-owned conversations.

### C. Render Markdown on the Rails server — rejected

Server HTML would complicate the existing JSON transcript API, make streaming
or newly polled messages require a second rendering contract, and move a UI
formatting concern into the persistence/API boundary. It would still require a
browser trust decision for returned HTML.

## Threat-model delta: conversation organization writes

Rename and reorder are new Assistant write actions. This section is their
approved threat-model delta.

### Dedicated contracts

`PATCH /api/v1/assistant/conversations/:id`

```json
{"title":"Quarterly target triage"}
```

The JSON body must contain exactly one `title` string. Unknown keys and missing
or non-string titles return `400 bad_request`. Blank-after-strip titles and
titles over 200 characters return `422 validation_failed`. The route can update
only the owned conversation title.

`PATCH /api/v1/assistant/conversations/order`

```json
{"conversation_ids":[17,4,22]}
```

The JSON body must contain exactly one `conversation_ids` array with at most
1,000 unique positive integers. It must be an exact permutation of every
conversation currently owned by the session user. A malformed list returns
`invalid_order`; a well-formed list made stale by a create/delete in another
tab returns `conversation_order_stale`. Neither outcome mutates any position.

The endpoints are separately named and are not a generic metadata-update or
bulk-write proxy. No message, provider, user, status, expiry, draft, turn,
context, tool, send, schedule, execution, or delete behavior is reachable from
either contract.

### Authorization and revocation

- Both endpoints remain under `Api::V1::Assistant::BaseController`: signed
  same-origin session only, configured Assistant administrator only, CSRF
  protected, and bearer `Authorization` headers rejected.
- Both perform owner-scoped lookup; a foreign/missing conversation is `404`.
- Both require the global Assistant activation and an independent
  `Assistant::Setting#conversation_management_enabled` switch.
- The new switch defaults on for the approved feature, is disclosed and
  editable on the existing Assistant settings form, and is included in safe
  settings/bootstrap serialization. Turning it off immediately returns
  `503 conversation_management_disabled` without mutation. It does not affect
  reads, deletion, retention, turns, or Control Center authoring.
- Production activation remains gated by the independent Assistant production
  checklist. Operator approval authorizes implementation but is not production
  review evidence.

### Explicit human approval

Rename requires opening the Rename action and submitting the labelled form.
Reorder requires a drag/drop or a discrete Move action. These direct human UI
gestures are the approval; the LLM receives no organization tool and cannot
invoke either route. Delete retains an explicit confirmation prompt. There is
no background, model-initiated, inferred, or approval-free organization path.

### Audit and disclosure

Successful rename records `conversation.renamed`; successful reorder records
`conversation.reordered`; successful deletion records
`conversation.deleted`. Events include the human user ID, safe record IDs where
applicable, status, and closed scalar metadata (`operation`, `outcome`). They
never include old/new titles, ordered ID arrays, messages, Markdown, clipboard
content, or provider output. Toggle changes record
`conversation_management.enabled` or `.disabled`.

The settings page discloses what the switch enables. The history menu labels
every write action. Rename is modal, reorder is direct and reversible by
another move, and delete states its hard-delete consequence before the request.

### Abuse cases and stable outcomes

- Bearer token, unauthenticated session, non-admin session, or invalid CSRF:
  rejected by the existing Assistant base boundary.
- Foreign conversation rename/delete: `404` with no existence disclosure.
- Unknown rename/reorder keys or malformed scalar types: `400 bad_request`.
- Invalid title: `422 validation_failed` with title errors.
- Duplicate, omitted, foreign, negative, non-integer, oversized, or stale order:
  `422 invalid_order` or `409 conversation_order_stale`, no partial writes.
- Disabled organization switch/global activation: `503`, no mutation.
- Concurrent create/reorder: serialized by the user row lock; one complete
  order wins or the stale request fails, never a partial permutation.
- Audit failure: transaction rolls back the rename/reorder. Delete audit is
  recorded in the same transaction before hard deletion and its conversation
  foreign key may become null by the existing `ON DELETE SET NULL`; target ID
  remains metadata-only evidence.
- Markdown script/event/URL/parser-confusion payload: raw HTML is escaped,
  sanitizer strips disallowed nodes/attributes/protocols, and unsupported
  sanitization falls back to text.
- Clipboard denial or unavailable local storage: visible failure/default with
  no API mutation.

## Component boundaries

- `Assistant::Conversation`: history ordering scope, new-chat position, title
  validation, and transactional rename.
- `Assistant::ConversationOrganization`: exact order validation, locking,
  dense position updates, and reorder audit.
- `Api::V1::Assistant::ConversationsController`: closed request decoding,
  owner lookup, toggle checks, and stable HTTP envelopes.
- `assistant_api.js`: dedicated rename and reorder clients only.
- `assistant_history.js`: pure list movement and drag payload helpers.
- `assistant_markdown.js`: Marked configuration, DOMPurify allowlist, and
  text-only fallback; the only message rich-content boundary.
- `assistant_font_scale.js`: closed local preference parsing and bounded scale
  changes.
- `assistant_ui.js`: inert conversation rows, menus, avatar/card structure,
  Markdown fragment mounting, and copy buttons.
- `assistant_controller.js`: dialogs, context-menu positioning, drag lifecycle,
  optimistic persistence/rollback, clipboard feedback, and font controls.
- `_assistant.html.erb` and `application.css`: semantic controls, menu/dialog,
  stronger borders, neutral palette, and namespaced Markdown typography.

## Testing and verification

TDD is required for each behavior.

- Model/service tests cover new-chat position, deterministic history order,
  exact permutations, stale/foreign/duplicate/oversized arrays, no partial
  mutation, locking-visible outcomes, title normalization, and metadata-only
  audits.
- Integration tests cover closed schemas, CSRF/session/admin/ownership,
  disabled switch, success responses, stable status/error codes, OpenAPI, and
  delete audit/confirmation disclosure.
- JavaScript unit tests cover client paths, pure reorder helpers, context-menu
  semantics, safe title text, font-scale storage, copy callbacks, avatar order,
  Markdown output/fallback, and malicious fixtures.
- Sanitizer adversarial fixtures include scripts, inline handlers, SVG/MathML,
  `javascript:`/`data:` URLs, images, iframes, forms, styles, custom elements,
  namespace/parser-confusion payloads, and control characters. Tests assert
  useful Markdown survives while executable/active content does not.
- Static shell tests cover visible menu access, rename dialog, font controls,
  resize affordance, status regions, strong borders, and absence of cyan in the
  Assistant surface.
- Build Tailwind, run every JavaScript test, focused Rails suites, OpenAPI
  validation, `zeitwerk:check`, the full Rails suite, dependency/security
  checks relevant to the vendored JavaScript, and an authenticated live smoke
  against the Docker gateway.

## Supply-chain and upgrade policy

Marked and DOMPurify distributions and licenses are vendored under
`web/vendor/javascript` and pinned by importmap. Their exact versions and
SHA-256 digests are recorded beside the files. The browser makes no third-party
request. A dependency update is a reviewed security change: verify upstream
release provenance, replace the pinned file/digest/license metadata, rerun the
full malicious corpus and application suites, and do not widen the allowlist as
part of a routine version bump.

## Out of scope

- Profile-image upload, remote avatar URLs, or identity storage.
- Conversation folders, search, pinning, sharing, export, or bulk deletion.
- Rich-text composition, message editing/deletion, reactions, citations, or
  syntax-highlighting execution.
- Panel movement/docking or persisted position.
- Markdown images, embedded HTML, SVG, MathML, media, forms, or arbitrary
  attributes.
- Any LLM tool for rename, reorder, delete, clipboard, browser storage, or UI
  control.

## Completion record

Implementation completed on 2026-08-13. The shipped boundaries are recorded in
commits `9001dc3`, `d4d72e9`, `f066a0e`, `1602088`, and `5a3bef8`; the approved
design and implementation plan are in `571191a` and `4d27246`.

Verification evidence:

- A clean `npm ci` installed 43 packages with zero reported vulnerabilities.
  Vendored Marked and DOMPurify SHA-256 values exactly matched
  `assistant-markdown-vendor.json`.
- The complete JavaScript suite passed 101 tests, including DOMPurify's
  adversarial corpus and real Stimulus/jsdom deferred-response coverage for
  history races, rename dismissal, optimistic ordering, focus restoration,
  context-menu boundaries, and keyboard movement.
- The focused Assistant/model/service/API/OpenAPI/static suite passed 200 tests
  with 1,163 assertions. The full Rails suite passed 1,307 tests with 6,572
  assertions and no failures, errors, or skips.
- Tailwind CSS v4.3.1 built successfully; `bin/rails zeitwerk:check` reported
  all good; `git diff --check` was clean.
- An authenticated smoke at `http://172.17.0.1:5000` returned the expected
  login redirect plus `200` for the shell and bootstrap. The final controller,
  UI helper, Markdown boundary, Marked, and DOMPurify fingerprinted assets all
  returned `200`. Two temporary conversations were created (`201`), one was
  renamed and the complete list reordered (`200`), persistence was fetched,
  the original order was restored, and both temporary records were deleted.
  Cleanup was verified afterward.
- No provider turn was invoked during live verification. Malicious Markdown
  stayed within the local jsdom sanitizer corpus, avoiding external model cost
  or provider retention. No credentials, transcript bodies, or provider output
  were recorded in verification evidence.
- Independent review initially found async history races, rename-dismissal
  ambiguity, lost rerender focus, and missing controller-level tests. Those
  issues were fixed; follow-up review reported no remaining Critical or
  Important findings and assessed the change ready to merge.
- A post-completion browser reproduction found that Propshaft served the
  vendored `.mjs` DOMPurify file with a blank media type. Chromium therefore
  rejected the sanitizer dependency and Stimulus could not register the chat
  controller. The byte-identical vendored module now uses a `.js` asset name,
  is served as `text/javascript`, and an integration regression test verifies
  that MIME boundary. A real Chromium click then opened the panel and loaded
  the Assistant bootstrap successfully.

This implementation does not itself satisfy the independent Assistant
production-activation checklist; that gate remains unchanged.
