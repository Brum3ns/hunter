# Assistant Conversation Workspace Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use task checkboxes for tracking.

**Goal:** Deliver owner-scoped conversation rename/reorder/delete controls and a Hunter-native, resizable, scalable chat that safely renders Markdown with avatars and per-message copy actions.

**Architecture:** Store custom history order on `Assistant::Conversation`, enforce rename/reorder through two closed session-only Rails contracts, and isolate order validation in a transactional service. Keep raw transcript bodies in JSON; a focused browser module parses with vendored Marked and sanitizes to a DOM fragment with vendored DOMPurify, while separate pure modules own list movement and the local font preference.

**Tech Stack:** Ruby 3.3.6, Rails 8/Active Record/PostgreSQL, Stimulus/importmap/Propshaft, Tailwind CSS v4, Marked 18.0.9, DOMPurify 3.4.13, Node 24 test runner, jsdom 30.0.1 for sanitizer tests, Minitest.

## Global Constraints

- Rename and reorder remain dedicated, owner-scoped, session-only, administrator-only, same-origin CSRF-protected endpoints; bearer authorization is rejected.
- Rename accepts exactly `{ "title": string }`; reorder accepts exactly `{ "conversation_ids": positive_integer[] }` with at most 1,000 unique IDs and requires a complete current owned permutation.
- Both organization writes require global Assistant activation plus `Assistant::Setting#conversation_management_enabled`; the independent switch defaults on and is disclosed, serialized, editable, and audited.
- The LLM receives no rename, reorder, delete, clipboard, browser-storage, or UI-control tool.
- Audit events never contain titles, ordered arrays, messages, Markdown, clipboard content, or provider output.
- Message HTML tokens are escaped before sanitization; DOMPurify receives a closed tag/attribute allowlist and returns the final fragment; no post-sanitize mutation is allowed.
- Pin locally vendored Marked 18.0.9 and DOMPurify 3.4.13; make no runtime CDN request.
- Markdown images, raw HTML, SVG, MathML, media, forms, frames, scripts, styles, classes, IDs, custom elements, event handlers, and data/ARIA attributes are prohibited.
- Font scale values are exactly 87.5%, 100%, 112.5%, and 125%; local storage contains only `{ "index": integer }` at `hunter:assistant-font-scale:v1`.
- Assistant-specific colors are neutral black/white/zinc; amber and rose remain semantic; no Assistant cyan class remains and global brand tokens are unchanged.
- Preserve the existing 680×780 anchored panel defaults, top-left pointer/keyboard resize behavior, mobile full-screen fallback, retention disclosure, context/draft security behavior, and Enter/Shift+Enter semantics.
- Follow strict RED → GREEN → REFACTOR. Do not write production behavior before its focused test has failed for the expected missing behavior.

---

### Task 1: Persist and audit conversation organization

**Files:**
- Create: `web/db/migrate/20260813000000_add_assistant_conversation_workspace.rb`
- Create: `web/app/services/assistant/conversation_organization.rb`
- Create: `web/test/services/assistant/conversation_organization_test.rb`
- Modify: `web/db/schema.rb`
- Modify: `web/app/models/assistant/conversation.rb`
- Modify: `web/app/models/assistant/setting.rb`
- Modify: `web/app/services/assistant/audit.rb`
- Modify: `web/test/models/assistant/conversation_test.rb`
- Modify: `web/test/models/assistant/setting_test.rb`
- Modify: `web/test/fixtures/assistant_settings.yml`

**Interfaces:**
- Produces: `Assistant::Conversation.history_ordered`, `Assistant::Conversation#rename_by!(actor:, title:)`, new-chat `history_position`, and `Assistant::ConversationOrganization.reorder!(user:, conversation_ids:)`.
- Produces: `Assistant::ConversationOrganization::InvalidOrder#code` with `invalid_order` or `conversation_order_stale`.
- Produces: `Assistant::Setting#conversation_management_enabled?`, `.enable_conversation_management!(user:)`, and `.disable_conversation_management!(user:)`.

- [x] **Step 1: Write failing model/service tests for ordering, rename, exact permutations, atomic failure, and the independent toggle**

Add literal expectations such as:

```ruby
test "history order prefers saved positions and leaves legacy rows deterministic" do
  first = assistant_conversations(:one)
  second = Assistant::Conversation.create!(
    user: first.user, provider_profile: first.provider_profile,
    title: "Second", expires_at: 6.days.from_now, history_position: -1
  )

  assert_equal [ second.id, first.id ],
    first.user.assistant_conversations.history_ordered.pluck(:id)
end

test "rename strips the title and audits no title content" do
  conversation = assistant_conversations(:one)

  conversation.rename_by!(actor: users(:one), title: "  Triage notes  ")

  assert_equal "Triage notes", conversation.reload.title
  event = Assistant::AuditEvent.find_by!(event: "conversation.renamed")
  assert_equal users(:one).id, event.user_id
  assert_equal conversation.id, event.conversation_id
  refute_includes event.attributes.to_json, "Triage notes"
end

test "reorder requires the exact owned set and never partially writes" do
  user = users(:one)
  first = assistant_conversations(:one)
  second = Assistant::Conversation.start!(
    user: user, provider_profile: assistant_provider_profiles(:openai)
  )

  Assistant::ConversationOrganization.reorder!(
    user: user, conversation_ids: [ first.id, second.id ]
  )
  assert_equal [ first.id, second.id ], user.assistant_conversations.history_ordered.pluck(:id)

  before = user.assistant_conversations.order(:id).pluck(:id, :history_position)
  error = assert_raises(Assistant::ConversationOrganization::InvalidOrder) do
    Assistant::ConversationOrganization.reorder!(
      user: user, conversation_ids: [ first.id, users(:two).assistant_conversations.first.id ]
    )
  end
  assert_equal "conversation_order_stale", error.code
  assert_equal before, user.assistant_conversations.order(:id).pluck(:id, :history_position)
end
```

Cover duplicate, negative, string, omitted, extra, and 1,001-element arrays as
separate table cases; assert malformed shapes use `invalid_order`, well-formed
non-permutations use `conversation_order_stale`, and only successful calls
create `conversation.reordered` without the ID array in audit JSON. Test that
new chats take a position before the current minimum. Test enable/disable
methods flip and audit the new setting without affecting
`control_center_write_enabled`.

- [x] **Step 2: Run the focused tests and verify RED**

Run:

```bash
cd web
bin/rails test test/models/assistant/conversation_test.rb test/models/assistant/setting_test.rb test/services/assistant/conversation_organization_test.rb
```

Expected: failures identify the missing column, scope, methods, service, and
setting.

- [x] **Step 3: Add the migration and minimal transactional implementation**

Migration body:

```ruby
class AddAssistantConversationWorkspace < ActiveRecord::Migration[8.1]
  def change
    add_column :assistant_conversations, :history_position, :bigint
    add_index :assistant_conversations, %i[user_id history_position],
      name: "idx_assistant_conversations_user_history"
    add_column :assistant_settings, :conversation_management_enabled,
      :boolean, null: false, default: true
  end
end
```

Implement `history_ordered` with
`arel_table[:history_position].asc.nulls_last`, `updated_at: :desc`, and
`id: :desc`. In `start!`, lock the user in a transaction, read the owned minimum
position, and create with `(minimum || 1) - 1`. `rename_by!` must reject a
non-owner actor, strip only string input, update under lock, and record
`conversation.renamed` in the same transaction.

`ConversationOrganization.reorder!` validates the raw array before opening its
transaction, then locks the user and every owned conversation ordered by ID,
compares sorted IDs, updates `history_position` with `update_columns` without
touching timestamps, and records one metadata-only audit event. Add
`count` to `Assistant::Audit::METADATA_KEYS` only if the implementation records
the safe scalar list length; never record the IDs.

Add setting class/instance enable/disable methods that record
`conversation_management.enabled`/`.disabled` with user ID and closed
`operation`/`outcome` metadata.

- [x] **Step 4: Migrate and run the focused tests to verify GREEN**

Run:

```bash
cd web
bin/rails db:migrate
bin/rails test test/models/assistant/conversation_test.rb test/models/assistant/setting_test.rb test/services/assistant/conversation_organization_test.rb
```

Expected: all focused tests pass with zero errors.

- [x] **Step 5: Commit the data boundary**

```bash
git add web/db/migrate/20260813000000_add_assistant_conversation_workspace.rb web/db/schema.rb web/app/models/assistant/conversation.rb web/app/models/assistant/setting.rb web/app/services/assistant/audit.rb web/app/services/assistant/conversation_organization.rb web/test/models/assistant/conversation_test.rb web/test/models/assistant/setting_test.rb web/test/services/assistant/conversation_organization_test.rb web/test/fixtures/assistant_settings.yml
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Add audited Assistant conversation organization persistence."
```

### Task 2: Expose closed rename/reorder routes and revocation disclosure

**Files:**
- Modify: `web/config/routes.rb`
- Modify: `web/app/controllers/api/v1/assistant/base_controller.rb`
- Modify: `web/app/controllers/api/v1/assistant/bootstrap_controller.rb`
- Modify: `web/app/controllers/api/v1/assistant/conversations_controller.rb`
- Modify: `web/app/controllers/api/v1/assistant/settings_controller.rb`
- Modify: `web/app/views/settings/_assistant.html.erb`
- Modify: `web/config/openapi/assistant.yaml`
- Modify: `web/test/integration/api/v1/assistant/conversations_test.rb`
- Modify: `web/test/integration/api/v1/assistant/provider_profiles_test.rb`
- Modify: `web/test/integration/api/v1/openapi_test.rb`
- Modify: `web/test/integration/settings/assistant_test.rb`

**Interfaces:**
- Produces: `PATCH /api/v1/assistant/conversations/:id` with exact `{title}`.
- Produces: `PATCH /api/v1/assistant/conversations/order` routed to `reorder` with exact `{conversation_ids}`.
- Produces: safe `conversation_management_enabled` in settings/bootstrap and the existing settings update contract.

- [x] **Step 1: Write failing integration tests for success and every fail-closed boundary**

Add tests that:

```ruby
patch "/api/v1/assistant/conversations/#{conversation.id}",
  params: { title: "  Renamed chat  " }, as: :json
assert_response :success
assert_equal "Renamed chat", response.parsed_body.fetch("title")

patch "/api/v1/assistant/conversations/order",
  params: { conversation_ids: [ second.id, conversation.id ] }, as: :json
assert_response :success
assert_equal [ second.id, conversation.id ],
  response.parsed_body.fetch("conversations").map { |item| item.fetch("id") }
```

Also assert unknown keys/missing/non-string bodies return `400 bad_request`;
blank/long title returns `422 validation_failed`; foreign rename returns 404;
duplicate/non-integer order returns `422 invalid_order`; stale complete-looking
order returns `409 conversation_order_stale`; and disabled global or
organization switches return 503 with no mutation. Extend delete coverage to
assert one `conversation.deleted` event whose JSON omits the title and body.
Use the existing authentication test patterns to prove bearer, non-admin, and
missing session rejection; use the existing forged-CSRF test pattern to prove
mutation rejection.

Add settings tests proving serialization, form disclosure, toggle update, and
toggle audit. Add OpenAPI assertions that both bodies have
`additionalProperties: false`, exact required fields, integer items, and a
1,000-item maximum.

- [x] **Step 2: Run the focused integration tests and verify RED**

Run:

```bash
cd web
bin/rails test test/integration/api/v1/assistant/conversations_test.rb test/integration/api/v1/assistant/authentication_test.rb test/integration/api/v1/assistant/provider_profiles_test.rb test/integration/settings/assistant_test.rb test/integration/api/v1/openapi_test.rb
```

Expected: failures name the missing routes/actions/setting field/OpenAPI paths.

- [x] **Step 3: Implement exact decoding, authorization, ordering, and audit**

Route shape:

```ruby
resources :conversations, only: %i[index show create update destroy] do
  patch :order, on: :collection, action: :reorder
  resources :turns, only: %i[create show], shallow: true do
    post :cancel, on: :member
  end
end
```

In the Assistant base controller, add a helper that requires both activation
and `conversation_management_enabled?`, returning
`{ error: "conversation_management_disabled" }` with 503 for the independent
toggle. In the conversations controller, gate `update`/`reorder`, use
`request.request_parameters` to require exact string keys before model/service
calls, map `InvalidOrder` codes to 422 or 409, and return the authoritative
`history_ordered` list after reorder. Use `history_ordered` in index and
bootstrap.

Wrap direct deletion and `conversation.deleted` audit in one transaction,
recording only user ID, target type/ID, status, operation, and outcome. Extend
settings serialization/update/form with the independently revocable checkbox
and its explicit explanation.

Document exact schemas, response codes, session-only security, revocation, and
no generic update fields in OpenAPI.

- [x] **Step 4: Run the focused integration tests and verify GREEN**

Run the command from Step 2. Expected: all tests pass.

- [x] **Step 5: Commit the HTTP boundary**

```bash
git add web/config/routes.rb web/app/controllers/api/v1/assistant web/app/views/settings/_assistant.html.erb web/config/openapi/assistant.yaml web/test/integration/api/v1/assistant web/test/integration/api/v1/openapi_test.rb web/test/integration/settings/assistant_test.rb
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Add closed Assistant conversation management routes."
```

### Task 3: Add pure history ordering, API clients, and font preference

**Files:**
- Create: `web/app/javascript/lib/assistant_history.js`
- Create: `web/app/javascript/lib/assistant_font_scale.js`
- Create: `web/test/javascript/assistant_history_test.mjs`
- Create: `web/test/javascript/assistant_font_scale_test.mjs`
- Modify: `web/app/javascript/lib/assistant_api.js`
- Modify: `web/test/javascript/assistant_controller_test.mjs`

**Interfaces:**
- Produces: `reorderConversation(conversations, draggedId, targetId, placement)`, `moveConversation(conversations, id, direction)`, and `conversationIds(conversations)`.
- Produces: `FONT_SCALE_STORAGE_KEY`, `FONT_SCALES`, `loadFontScaleIndex(storage)`, `saveFontScaleIndex(storage, index)`, and `changeFontScale(index, delta)`.
- Produces: `assistantApi.renameConversation(id, title)` and `assistantApi.reorderConversations(ids)`.

- [x] **Step 1: Write failing pure/client tests**

Use hand-derived list expectations:

```js
assert.deepEqual(
  reorderConversation([{ id: 1 }, { id: 2 }, { id: 3 }], 1, 3, "after").map((c) => c.id),
  [2, 3, 1],
)
assert.deepEqual(
  moveConversation([{ id: 1 }, { id: 2 }, { id: 3 }], 2, -1).map((c) => c.id),
  [2, 1, 3],
)
assert.deepEqual(changeFontScale(1, 1), { index: 2, value: 1.125 })
```

Test before/after, string-vs-number IDs, missing IDs, same IDs, top/bottom
clamping, input immutability, exact font storage keys, invalid/extra/non-integer
fallback, and storage exceptions. Extend the API request test to assert encoded
PATCH routes, CSRF, and exact JSON bodies.

- [x] **Step 2: Run tests and verify RED**

```bash
cd web
node --test test/javascript/assistant_history_test.mjs test/javascript/assistant_font_scale_test.mjs test/javascript/assistant_controller_test.mjs
```

Expected: missing-module/export failures.

- [x] **Step 3: Implement the minimal pure modules and API methods**

Use exactly:

```js
export const FONT_SCALE_STORAGE_KEY = "hunter:assistant-font-scale:v1"
export const FONT_SCALES = Object.freeze([0.875, 1, 1.125, 1.25])
export const DEFAULT_FONT_SCALE_INDEX = 1
```

Storage accepts only one `index` key and an in-range integer. Reorder helpers
return fresh arrays and never mutate conversation objects. API methods issue:

```js
PATCH /api/v1/assistant/conversations/:encoded_id  { title }
PATCH /api/v1/assistant/conversations/order        { conversation_ids: ids }
```

- [x] **Step 4: Run tests and verify GREEN**

Run the Step 2 command. Expected: all pass.

- [x] **Step 5: Commit the browser state primitives**

```bash
git add web/app/javascript/lib/assistant_api.js web/app/javascript/lib/assistant_history.js web/app/javascript/lib/assistant_font_scale.js web/test/javascript/assistant_controller_test.mjs web/test/javascript/assistant_history_test.mjs web/test/javascript/assistant_font_scale_test.mjs
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Add Assistant history and font preference primitives."
```

### Task 4: Vendor and prove the Markdown security boundary

**Files:**
- Create: `web/package.json`
- Create: `web/package-lock.json`
- Create: `web/vendor/javascript/marked.esm.js`
- Create: `web/vendor/javascript/dompurify.es.mjs`
- Create: `web/vendor/javascript/licenses/marked-LICENSE.md`
- Create: `web/vendor/javascript/licenses/dompurify-LICENSE`
- Create: `web/vendor/javascript/assistant-markdown-vendor.json`
- Create: `web/app/javascript/lib/assistant_markdown.js`
- Create: `web/test/javascript/assistant_markdown_test.mjs`
- Modify: `web/config/importmap.rb`

**Interfaces:**
- Produces: `safeDisplayText(value)` and `renderMarkdownFragment(documentRef, body, options = {})`.
- `options.purifier` and `options.parser` exist only to test explicit unsupported/error fallback; normal browser calls use the pinned imports.

- [x] **Step 1: Add pinned packages and vendor exact distributions mechanically**

Create a private package file with exact dev dependencies:

```json
{
  "private": true,
  "devDependencies": {
    "dompurify": "3.4.13",
    "jsdom": "30.0.1",
    "marked": "18.0.9"
  }
}
```

Run `cd web && npm install --package-lock-only && npm ci`, then copy
`node_modules/marked/lib/marked.esm.js`,
`node_modules/dompurify/dist/purify.es.mjs`, and the two upstream license files
into the listed vendor paths. Record version, upstream URL, source file, and
SHA-256 for each distribution in `assistant-markdown-vendor.json`. Pin
`marked`/`dompurify` to those local Propshaft assets in importmap.

- [x] **Step 2: Write failing jsdom tests for useful Markdown, raw HTML, malicious URLs, active elements, and fallback**

Initialize jsdom before dynamically importing the module. Assert real returned
DOM behavior, not source strings:

```js
const fragment = renderMarkdownFragment(document, [
  "# Heading",
  "**bold** and `code`",
  '<img src=x onerror="alert(1)">',
  '[bad](javascript:alert(1))',
  '<svg><a xlink:href="javascript:alert(1)">x</a></svg>',
  '<form><input autofocus onfocus="alert(1)"></form>',
].join("\n\n"))
const host = document.createElement("div")
host.append(fragment)

assert.equal(host.querySelector("h1")?.textContent, "Heading")
assert.equal(host.querySelector("strong")?.textContent, "bold")
assert.equal(host.querySelector("code")?.textContent, "code")
assert.equal(host.querySelector("img,svg,form,input,script,iframe,style"), null)
assert.equal(host.querySelector('[onerror],[onfocus],[style],[class],[id]'), null)
assert.equal(host.querySelector('a[href^="javascript:"],a[href^="data:"]'), null)
assert.match(host.textContent, /<img src=x onerror=/)
```

Add table/list/blockquote/link survival tests, control-character replacement,
DOMPurify unsupported fallback, parser throw fallback, purifier throw fallback,
and a mutation-XSS fixture (`<math><mtext><table><mglyph><style><!--</style><img
title=\"--></mglyph><img src=1 onerror=alert(1)>\">`). Fallback must return one
text node containing the inert original display text.

- [x] **Step 3: Run the Markdown test and verify RED**

```bash
cd web
npm ci
node --test test/javascript/assistant_markdown_test.mjs
```

Expected: missing `assistant_markdown.js` failure.

- [x] **Step 4: Implement the one-way parser/sanitizer pipeline**

Instantiate a private `Marked` parser with `gfm: true`, `breaks: true`,
`async: false`, and a raw-HTML renderer that HTML-escapes the token text. Call
DOMPurify with `RETURN_DOM_FRAGMENT: true`, `RETURN_TRUSTED_TYPE: false`,
`ALLOW_ARIA_ATTR: false`, `ALLOW_DATA_ATTR: false`, the exact tag list from the
spec, and `ALLOWED_ATTR: ["href", "title"]`. Do not combine
`USE_PROFILES` with `ALLOWED_TAGS`; DOMPurify documents that the former
overrides the latter. Do not mutate the returned fragment. Catch every parser
or sanitizer error and return `documentRef.createTextNode(displayText)`.

- [x] **Step 5: Run the Markdown and complete JavaScript suite to verify GREEN**

```bash
cd web
node --test test/javascript/assistant_markdown_test.mjs test/javascript/*.mjs
```

Expected: zero failures; malicious fixtures contain no active nodes or
attributes.

- [x] **Step 6: Commit the pinned rendering boundary**

```bash
git add web/package.json web/package-lock.json web/vendor/javascript/marked.esm.js web/vendor/javascript/dompurify.es.mjs web/vendor/javascript/licenses web/vendor/javascript/assistant-markdown-vendor.json web/config/importmap.rb web/app/javascript/lib/assistant_markdown.js web/test/javascript/assistant_markdown_test.mjs
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Add a pinned sanitized Markdown rendering boundary."
```

### Task 5: Build history interactions and message controls

**Files:**
- Modify: `web/app/javascript/lib/assistant_ui.js`
- Modify: `web/app/javascript/controllers/assistant_controller.js`
- Modify: `web/app/views/layouts/_assistant.html.erb`
- Modify: `web/test/javascript/assistant_controller_test.mjs`
- Modify: `web/test/views/assistant_shell_markup_test.rb`
- Modify: `web/test/integration/assistant_shell_test.rb`

**Interfaces:**
- Consumes: Tasks 2–4 routes/helpers and the existing panel sizing API.
- Produces: shared context/overflow menu, rename dialog, pointer drag/drop,
  move fallbacks, confirmed delete, avatars, message copy, and font buttons.

- [x] **Step 1: Write failing UI and shell tests for accessible interactions**

Extend the fake DOM only with real methods the helpers consume (`removeAttribute`,
`classList`, `createTextNode`, `focus`, and drag event listeners). Assert:

- each history row is draggable and contains a title button plus an
  `aria-haspopup="menu"` overflow button;
- title/context-menu events preserve adversarial title text and invoke the
  correct callback/ID;
- active selection uses `aria-current`, move boundaries disable correctly, and
  drag callbacks distinguish before/after;
- message rows contain avatar and article in Assistant order and article/avatar
  in user order;
- each card's Copy button passes the original Markdown body;
- the Markdown fragment, not raw source, is mounted in the body container;
- shell markup has a `role="menu"`, four menu actions, labelled rename dialog,
  font decrease/increase controls, scale/status live region, more visible resize
  help, and shared delete confirmation disclosure.

- [x] **Step 2: Run focused JS/static shell tests and verify RED**

```bash
cd web
node --test test/javascript/assistant_controller_test.mjs test/javascript/assistant_history_test.mjs test/javascript/assistant_font_scale_test.mjs test/javascript/assistant_markdown_test.mjs
bundle exec ruby test/views/assistant_shell_markup_test.rb
bin/rails test test/integration/assistant_shell_test.rb
```

Expected: failures identify missing row/menu/dialog/avatar/copy/font controls.

- [x] **Step 3: Implement inert rows, message cards, and static controls**

Refactor `renderConversationList` to create a draggable row with separate title
and overflow buttons using only `createElement`, `textContent`, attributes, and
listeners. Wire click, contextmenu, `Shift+F10`, Context Menu key, dragstart,
dragover, drop, and dragend through callbacks; never interpolate a title into
HTML, selectors, or action attributes.

Refactor `appendMessage(documentRef, container, message, callbacks)` into an
avatar/card row. Mount `renderMarkdownFragment` in a dedicated
`.assistant-markdown` element and wire a plain-text Copy button to
`callbacks.onCopy(message)`. Keep role labels and robust wrapping.

Add the one static menu, rename dialog/form, A−/A+ buttons, scale text, status
region, and visible resize tooltip in ERB. Keep every existing Assistant target,
disclosure string, context option, draft action, and composer behavior.

- [x] **Step 4: Wire controller state and effectful gestures**

On connect, restore/apply the font index; bind outside-menu dismissal; initialize
`historyMenuConversation`, `historyMenuTrigger`, `draggedConversationId`, and
`reorderInFlight`. On disconnect, remove document listeners and close menu.

Use a single `openHistoryMenu(conversation, trigger, point)` for right-click and
overflow. Position within viewport bounds, update move disabled states, set
`aria-expanded`, and focus Rename. Escape closes the menu before closing the
panel. Rename submits the exact API call, updates local/current title only from
the server response, rerenders, and reports status.

For drag/move, compute the next list with Task 3 helpers, render optimistically,
PATCH the complete ID list, replace with the authoritative response on success,
and restore the prior list plus status on failure. Ignore a second reorder while
one is in flight.

Use one `confirmConversationDeletion(conversation)` path for toolbar and menu.
The confirmation includes the inert title and exact retention consequence;
cancel sends no request. Deleting a non-current row leaves the current chat
open; deleting current returns to the start screen.

Copy `message.body` through `navigator.clipboard.writeText` and report success
or failure. Apply font values through `--assistant-message-scale`, persist only
the index, update `87.5%`/`100%`/`112.5%`/`125%`, and disable buttons at bounds.

- [x] **Step 5: Run the focused tests and verify GREEN**

Run the Step 2 command. Expected: all pass.

- [x] **Step 6: Commit the workspace interactions**

```bash
git add web/app/javascript/lib/assistant_ui.js web/app/javascript/controllers/assistant_controller.js web/app/views/layouts/_assistant.html.erb web/test/javascript/assistant_controller_test.mjs web/test/views/assistant_shell_markup_test.rb web/test/integration/assistant_shell_test.rb
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Add accessible Assistant conversation workspace controls."
```

### Task 6: Apply Hunter-native borders, typography, and neutral colors

**Files:**
- Modify: `web/app/assets/tailwind/application.css`
- Modify: `web/app/views/layouts/_assistant.html.erb`
- Modify: `web/app/javascript/lib/assistant_ui.js`
- Modify: `web/test/javascript/assistant_controller_test.mjs`
- Modify: `web/test/views/assistant_shell_markup_test.rb`

**Interfaces:**
- Produces: `.assistant-markdown` typography and `--assistant-message-scale`.
- Preserves: global `--color-brand` values for non-Assistant modules.

- [x] **Step 1: Write failing rendered-class and typography behavior tests**

Assert message/list/context/action elements use zinc/black/white classes and
contain no `cyan-` token. In the static shell test, assert the panel has a
strong neutral border/ring, messages region is visually bounded, resize handle
has visible help, and Assistant nodes contain no cyan class. Assert the built
DOM uses the scale custom property and semantic Markdown selectors for code,
pre, tables, blockquotes, headings, and links.

- [x] **Step 2: Run UI/static tests and verify RED**

```bash
cd web
node --test test/javascript/assistant_controller_test.mjs
bundle exec ruby test/views/assistant_shell_markup_test.rb
```

Expected: current cyan classes and missing Markdown typography fail.

- [x] **Step 3: Implement the neutral palette and namespaced typography**

Replace Assistant cyan accents with inverse zinc buttons, zinc active rows,
neutral focus rings, and higher-contrast zinc borders. Keep amber status and
rose delete/error states. Give the panel and message log visible neutral
boundaries in both themes. Do not alter global brand variables.

Add namespaced Markdown rules for vertical rhythm, heading weights, list
indentation, quote border, inline code, scrollable fenced code, table borders,
and underlined links. Set base size with
`font-size: calc(0.875rem * var(--assistant-message-scale, 1))`; ensure nested
code uses `em` sizing so scaling remains coherent.

- [x] **Step 4: Build Tailwind and run focused tests to verify GREEN**

```bash
cd web
bin/rails tailwindcss:build
node --test test/javascript/assistant_controller_test.mjs test/javascript/assistant_markdown_test.mjs
bundle exec ruby test/views/assistant_shell_markup_test.rb
```

Expected: build and tests pass; no Assistant cyan classes remain.

- [x] **Step 5: Commit the Hunter visual finish**

```bash
git add web/app/assets/tailwind/application.css web/app/views/layouts/_assistant.html.erb web/app/javascript/lib/assistant_ui.js web/test/javascript/assistant_controller_test.mjs web/test/views/assistant_shell_markup_test.rb
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Align the Assistant workspace with Hunter visual styling."
```

### Task 7: Full security and live verification

**Files:**
- Modify: `docs/superpowers/specs/2026-08-13-assistant-conversation-workspace-design.md` (completion record only after evidence exists)
- Modify: `docs/superpowers/plans/2026-08-13-assistant-conversation-workspace.md` (check boxes/completion record only after evidence exists)

**Interfaces:**
- Verifies: every deliverable and no regression outside the Assistant surface.

- [x] **Step 1: Reinstall exact JavaScript test dependencies and verify vendor digests**

```bash
cd web
npm ci
sha256sum vendor/javascript/marked.esm.js vendor/javascript/dompurify.es.mjs
node --test test/javascript/*.mjs
```

Expected: digests exactly match `assistant-markdown-vendor.json`; all JavaScript
tests pass.

- [x] **Step 2: Run focused Rails, OpenAPI, and static security tests**

```bash
cd web
bundle exec ruby test/views/assistant_shell_markup_test.rb
bin/rails test test/models/assistant/conversation_test.rb test/models/assistant/setting_test.rb test/services/assistant/conversation_organization_test.rb test/services/assistant/audit_test.rb test/integration/api/v1/assistant test/integration/assistant_shell_test.rb test/integration/assistant_end_to_end_test.rb test/integration/settings/assistant_test.rb test/integration/api/v1/openapi_test.rb
bin/rails zeitwerk:check
```

Expected: zero failures/errors and Zeitwerk reports all expected files loaded.

- [x] **Step 3: Run build, full Rails suite, and repository checks**

Source the deployment `.env` without printing it, clear inherited
`CONTROL_CENTER_COMMAND_ALLOWLIST`, and point tests to the Docker-gateway test
database exactly as the established workflow requires:

```bash
cd web
set -a; source ../.env; set +a
CONTROL_CENTER_COMMAND_ALLOWLIST= DB_HOST=172.17.0.1 DB_PORT=5433 DB_DATABASE_TEST=hunter_test PATH=/opt/rbenv/shims:/usr/local/go/bin:$PATH bin/rails tailwindcss:build
CONTROL_CENTER_COMMAND_ALLOWLIST= DB_HOST=172.17.0.1 DB_PORT=5433 DB_DATABASE_TEST=hunter_test PATH=/opt/rbenv/shims:/usr/local/go/bin:$PATH bin/rails test
CONTROL_CENTER_COMMAND_ALLOWLIST= DB_HOST=172.17.0.1 DB_PORT=5433 DB_DATABASE_TEST=hunter_test PATH=/opt/rbenv/shims:/usr/local/go/bin:$PATH bin/rails zeitwerk:check
cd ..
git diff --check
git status --short
```

Expected: Tailwind exits 0, full Rails has zero failures/errors, Zeitwerk passes,
no whitespace errors, and only intended completion-document changes remain.

- [x] **Step 4: Perform an authenticated live smoke against port 5000**

After the Docker app is healthy at `http://172.17.0.1:5000`, use a temporary
cookie jar and credentials loaded from `.env` without echoing them. Verify the
rendered shell contains menu/dialog/font/resize controls; create two test
conversations, rename one with PATCH, reorder the complete owned list, fetch to
verify persistence, submit malicious Markdown through the normal turn path only
if doing so will not invoke an external provider, and delete test records with
the ordinary endpoint. Never log credentials or response bodies containing
transcript content. If provider invocation cannot be avoided, verify Markdown
only through the jsdom malicious corpus and do not send a live turn.

Expected: 2xx/204 routes, persisted title/order, owner isolation, no browser
console/import error reported by the rendered asset graph, and cleanup succeeds.

- [x] **Step 5: Record evidence, self-review, and commit completion**

Update the spec status with actual command counts/results and mark plan boxes
only for steps actually executed. Review for placeholders, contradictions,
scope creep, secrets, generated artifacts, and accidental Assistant/global
cyan changes. Then:

```bash
git add docs/superpowers/specs/2026-08-13-assistant-conversation-workspace-design.md docs/superpowers/plans/2026-08-13-assistant-conversation-workspace.md
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Complete and verify the Assistant conversation workspace."
git status --short
```

Expected: completion commit succeeds and the worktree is clean.

## Completion record

Completed and verified on 2026-08-13.

- Tasks 1–4 were committed as `9001dc3`, `d4d72e9`, `f066a0e`, and `1602088`.
- The overlapping interaction and Hunter visual work in Tasks 5–6 was committed
  together as `5a3bef8` so its shell, runtime classes, namespaced CSS, importmap
  alias, and controller-level tests remained one passing unit.
- Clean-install JavaScript result: 101 tests passed; npm reported zero
  vulnerabilities; both vendor digests matched the recorded manifest.
- Focused Rails result: 200 tests, 1,163 assertions, zero failures/errors.
- Full Rails result: 1,307 tests, 6,572 assertions, zero failures/errors/skips.
- Tailwind and Zeitwerk passed. Authenticated port-5000 shell, asset, rename,
  reorder, persistence, cleanup, and current-controller checks passed without
  invoking an external provider.
- Two-pass independent review ended with no Critical or Important findings.
