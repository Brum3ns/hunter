# Assistant Chat UI Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a larger, polished Assistant chat panel that resizes from its top-left corner, remembers its desktop dimensions, and remains full-screen on mobile.

**Architecture:** Keep the existing Rails partial and Stimulus controller, but isolate all size validation, clamping, pointer math, and persistence in a dependency-free JavaScript module. The partial owns semantics and static structure; the controller wires browser events; inert DOM helpers continue to render API content safely with text nodes only.

**Tech Stack:** Rails 8 ERB, Stimulus, importmap, Tailwind CSS v4, Node test runner, Minitest integration tests.

**Status:** Complete and verified (2026-08-13).

## Completion record

All tasks below are delivered. Checkboxes record the final delivered state; the
historical RED commands were not reconstructed after implementation. Final
verification was run against the completed tree:

- Tailwind CSS v4.3.1 build: passed.
- JavaScript: 79 tests, 79 passed.
- Static Assistant shell markup: 3 runs, 17 assertions, 0 failures.
- Focused Assistant Rails integration: 6 runs, 80 assertions, 0 failures.
- Full Rails: 1,281 runs, 6,361 assertions, 0 failures.
- Rails autoloading: `zeitwerk:check` passed.
- Live authenticated rendered-shell smoke at the Docker gateway: passed.
- `git diff --check`: passed.

The completion audit also hardened disclosure-aware mobile focus trapping,
pointer-capture loss cleanup, resize announcements, modified-Enter handling,
duplicate keyboard-submit prevention, mobile header spacing, and dark-surface
contrast. These are presentation/input reliability changes only; no Assistant
capability, API, authorization, persistence, or security boundary changed.

## Global Constraints

- The panel stays anchored 16 px from the bottom-right and is resizable, not movable.
- Desktop defaults are 680 px by 780 px; minimums are 480 px by 520 px; maximums are viewport dimensions minus 32 px.
- Below 640 px the panel remains full-screen and stored desktop dimensions are not applied or overwritten.
- Persist only `{ "width": number, "height": number }` under `hunter:assistant-panel-size:v1`; never persist Assistant content or identity data.
- Existing Assistant capabilities, authorization, disclosures, validation, auditing, APIs, and security behavior remain unchanged.
- Preserve unrelated and existing uncommitted work, especially the current capability-copy changes in `web/app/views/layouts/_assistant.html.erb` and `web/test/integration/assistant_shell_test.rb`.
- Do not commit unless the user explicitly asks.

---

### Task 1: Pure panel sizing and persistence

**Files:**
- Create: `web/app/javascript/lib/assistant_panel_size.js`
- Create: `web/test/javascript/assistant_panel_size_test.mjs`

**Interfaces:**
- Produces: `PANEL_SIZE_STORAGE_KEY`, `DEFAULT_PANEL_SIZE`, `MIN_PANEL_SIZE`, `desktopPanel(viewport)`, `clampPanelSize(size, viewport)`, `resizeFromPointer(startSize, startPoint, currentPoint, viewport)`, `resizeFromKeyboard(size, key, step, viewport)`, `loadPanelSize(storage, viewport)`, and `savePanelSize(storage, size)`.
- Consumes: only a viewport shape `{ width, height }` and the Web Storage `getItem`/`setItem` interface.

- [x] **Step 1: Write failing unit tests for defaults, clamping, anchored pointer math, keyboard math, closed-schema persistence, and storage failures**

Create `web/test/javascript/assistant_panel_size_test.mjs` with focused tests equivalent to:

```js
import test from "node:test"
import assert from "node:assert/strict"
import {
  DEFAULT_PANEL_SIZE, PANEL_SIZE_STORAGE_KEY, clampPanelSize, desktopPanel,
  loadPanelSize, resizeFromKeyboard, resizeFromPointer, savePanelSize,
} from "../../app/javascript/lib/assistant_panel_size.js"

const viewport = { width: 1440, height: 1000 }

test("desktop sizing defaults and clamps to viewport bounds", () => {
  assert.equal(desktopPanel({ width: 639, height: 900 }), false)
  assert.equal(desktopPanel({ width: 640, height: 900 }), true)
  assert.deepEqual(clampPanelSize(DEFAULT_PANEL_SIZE, viewport), { width: 680, height: 780 })
  assert.deepEqual(clampPanelSize({ width: 1, height: 9999 }, viewport), { width: 480, height: 968 })
})

test("top-left pointer movement resizes an anchored panel", () => {
  assert.deepEqual(
    resizeFromPointer({ width: 680, height: 780 }, { x: 400, y: 300 }, { x: 336, y: 252 }, viewport),
    { width: 744, height: 828 },
  )
})

test("keyboard arrows grow toward top-left and shrink toward bottom-right", () => {
  assert.deepEqual(resizeFromKeyboard({ width: 680, height: 780 }, "ArrowLeft", 16, viewport), { width: 696, height: 780 })
  assert.deepEqual(resizeFromKeyboard({ width: 680, height: 780 }, "ArrowDown", 48, viewport), { width: 680, height: 732 })
})

test("storage accepts only the closed numeric shape and clamps restored values", () => {
  const values = new Map([[PANEL_SIZE_STORAGE_KEY, JSON.stringify({ width: 900, height: 900 })]])
  const storage = { getItem: (key) => values.get(key), setItem: (key, value) => values.set(key, value) }
  assert.deepEqual(loadPanelSize(storage, viewport), { width: 900, height: 900 })
  values.set(PANEL_SIZE_STORAGE_KEY, JSON.stringify({ width: 900, height: 900, message: "must reject" }))
  assert.deepEqual(loadPanelSize(storage, viewport), DEFAULT_PANEL_SIZE)
  assert.equal(savePanelSize(storage, { width: 720, height: 760 }), true)
  assert.deepEqual(JSON.parse(values.get(PANEL_SIZE_STORAGE_KEY)), { width: 720, height: 760 })
})

test("malformed data and unavailable storage fall back without throwing", () => {
  const broken = { getItem() { throw new Error("denied") }, setItem() { throw new Error("denied") } }
  assert.deepEqual(loadPanelSize(broken, viewport), DEFAULT_PANEL_SIZE)
  assert.equal(savePanelSize(broken, DEFAULT_PANEL_SIZE), false)
})
```

- [x] **Step 2: Run the test and verify RED**

Run: `cd web && node --test test/javascript/assistant_panel_size_test.mjs`

Expected: FAIL with `ERR_MODULE_NOT_FOUND` for `assistant_panel_size.js`.

- [x] **Step 3: Implement the pure sizing module**

Create the constants and functions with these rules:

```js
export const PANEL_SIZE_STORAGE_KEY = "hunter:assistant-panel-size:v1"
export const DEFAULT_PANEL_SIZE = Object.freeze({ width: 680, height: 780 })
export const MIN_PANEL_SIZE = Object.freeze({ width: 480, height: 520 })
export const DESKTOP_BREAKPOINT = 640
const VIEWPORT_GUTTER = 32

export function desktopPanel(viewport) { return viewport.width >= DESKTOP_BREAKPOINT }
export function clampPanelSize(size, viewport) {
  const maxWidth = Math.max(MIN_PANEL_SIZE.width, viewport.width - VIEWPORT_GUTTER)
  const maxHeight = Math.max(MIN_PANEL_SIZE.height, viewport.height - VIEWPORT_GUTTER)
  return {
    width: Math.min(Math.max(Number(size.width), MIN_PANEL_SIZE.width), maxWidth),
    height: Math.min(Math.max(Number(size.height), MIN_PANEL_SIZE.height), maxHeight),
  }
}
```

`resizeFromPointer` adds `startPoint.x - currentPoint.x` to width and
`startPoint.y - currentPoint.y` to height before clamping. Keyboard Left/Up add
the step to width/height and Right/Down subtract it. `loadPanelSize` catches all
errors, parses JSON, requires exactly the sorted keys `height,width`, requires
finite numeric values, and otherwise returns a fresh copy of the clamped
default. `savePanelSize` catches all errors and returns a boolean.

- [x] **Step 4: Run the focused test and verify GREEN**

Run: `cd web && node --test test/javascript/assistant_panel_size_test.mjs`

Expected: 5 tests pass, 0 fail.

### Task 2: Accessible resize shell and controller wiring

**Files:**
- Modify: `web/test/integration/assistant_shell_test.rb`
- Modify: `web/app/views/layouts/_assistant.html.erb`
- Modify: `web/app/javascript/controllers/assistant_controller.js`
- Modify: `web/app/assets/tailwind/application.css`

**Interfaces:**
- Consumes: Task 1 sizing and persistence functions.
- Produces: `resizeHandle`, `panel`, pointer lifecycle methods, keyboard resizing, viewport clamping, and full-screen mobile fallback.

- [x] **Step 1: Add failing shell assertions for the resize and disclosure semantics**

Extend `shell exposes accessible panel controls and safe empty regions` with:

```ruby
assert_select "#hunter-assistant-panel.assistant-panel[data-assistant-target='panel']"
assert_select "button[data-assistant-target='resizeHandle'][aria-label='Resize Hunter assistant'][data-action*='pointerdown->assistant#startResize'][data-action*='keydown->assistant#resizeWithKeyboard']"
assert_select "details[data-assistant-target='capabilityDisclosure'] > summary", text: /Data access & actions/i
assert_select "details[data-assistant-target='contextDisclosure'] > summary", text: /Add Hunter context/i
```

Keep the existing capability-copy assertions unchanged.

- [x] **Step 2: Run the integration test and verify RED**

Run: `cd web && bin/rails test test/integration/assistant_shell_test.rb`

Expected: FAIL because the panel class, resize handle, and disclosure targets do not exist.

- [x] **Step 3: Restructure the partial without changing behavior or capability copy**

In `_assistant.html.erb`:

- Add `assistant-panel` to the panel and remove the fixed desktop height/width utilities.
- Insert a desktop-only top-left `button` target with the exact label/actions from the test; include an inert diagonal-grip SVG and a focus ring.
- Keep `role="dialog"`, the existing title association, mobile full-screen classes, and `hidden` behavior.
- Wrap the existing complete capability paragraph in a closed `details` target whose summary is `Data access & actions`.
- Wrap the existing context-search section in a closed `details` target whose summary is `Add Hunter context`.
- Widen the desktop grid rail using `grid-cols-[10.5rem_minmax(0,1fr)] lg:grid-cols-[12rem_minmax(0,1fr)]` while retaining a usable mobile rail.

Add namespaced CSS:

```css
@media (min-width: 640px) {
  .assistant-panel { width: 680px; height: min(780px, calc(100dvh - 2rem)); }
}
.assistant-is-resizing,
.assistant-is-resizing * { cursor: nwse-resize; user-select: none; }
```

Use the button's Tailwind classes for its visible hover/focus affordance and
hide it below `sm`.

- [x] **Step 4: Wire resizing into the existing controller**

Import Task 1 functions. Add `resizeHandle` to targets. On `connect`, bind a
window resize callback and initialize `resizeState`; on `disconnect`, remove
the callback and any pointer listeners. On desktop `open`, load and apply the
stored size before focus moves into the panel. On mobile, clear inline width and
height.

`startResize(event)` records the current width/height and pointer coordinates,
adds `is-resizing`, calls `setPointerCapture`, and registers
`pointermove`/`pointerup`/`pointercancel` on the handle. Pointer move calls
`resizeFromPointer` and applies `style.width`/`style.height`. End/cancel removes
listeners and class, releases capture when held, and persists the final size.

`resizeWithKeyboard(event)` accepts only arrow keys, prevents default, uses 16
or 48 based on Shift, applies `resizeFromKeyboard`, stores, and updates a
dedicated polite live status such as `Current size 696 by 780 pixels.` while the
button retains a stable accessible name. `handleViewportResize` switches cleanly
between full-screen mobile and clamped desktop dimensions without overwriting
stored desktop dimensions on mobile. Pointer-capture loss follows the same
cleanup path as pointer up/cancel.

- [x] **Step 5: Run size and shell tests and verify GREEN**

Run: `cd web && node --test test/javascript/assistant_panel_size_test.mjs && bin/rails test test/integration/assistant_shell_test.rb`

Expected: all tests pass.

### Task 3: Conversation hierarchy, safer rendering, and composer ergonomics

**Files:**
- Modify: `web/test/javascript/assistant_controller_test.mjs`
- Modify: `web/app/javascript/lib/assistant_ui.js`
- Modify: `web/app/javascript/controllers/assistant_controller.js`
- Modify: `web/app/views/layouts/_assistant.html.erb`

**Interfaces:**
- Produces: `composerSubmitIntent(event)` and `renderConversationList(documentRef, container, conversations, options)` from `assistant_ui.js`.
- Preserves: every content-rendering path uses `textContent`; `innerHTML` remains prohibited.

- [x] **Step 1: Add failing unit tests for composer intent, list empty state, active state, and refreshed message classes**

Extend the existing Node test with:

```js
test("composer Enter submits while Shift+Enter and composition keep editing", () => {
  assert.equal(ui.composerSubmitIntent({ key: "Enter", shiftKey: false, isComposing: false }), true)
  assert.equal(ui.composerSubmitIntent({ key: "Enter", shiftKey: true, isComposing: false }), false)
  assert.equal(ui.composerSubmitIntent({ key: "Enter", shiftKey: false, isComposing: true }), false)
})

test("conversation list renders an inert empty state and marks the current chat", () => {
  const empty = new FakeElement("div")
  ui.renderConversationList(fakeDocument, empty, [], {})
  assert.match(empty.textContent, /No conversations yet/i)

  const list = new FakeElement("div")
  ui.renderConversationList(fakeDocument, list, [
    { id: 7, title: "Current" }, { id: 8, title: "Older" },
  ], { currentId: 7, onSelect() {} })
  assert.equal(list.children[0].attributes["aria-current"], "true")
  assert.match(list.children[0].className, /assistant-conversation-active/)
})
```

Add `className = ""`, `removeAttribute`, and `style` support to `FakeElement` only
as required by the real helper contract.

- [x] **Step 2: Run the Node test and verify RED**

Run: `cd web && node --test test/javascript/assistant_controller_test.mjs`

Expected: FAIL because `composerSubmitIntent` and `renderConversationList` are not exported.

- [x] **Step 3: Implement inert UI helpers and update the controller**

`composerSubmitIntent` returns true only for unmodified Enter outside IME
composition. `renderConversationList` uses only `createElement`, `textContent`,
and event listeners. It renders `No conversations yet` when empty, truncates
button titles, adds `assistant-conversation-active` plus `aria-current="true"`
for `currentId`, and removes `aria-current` from other entries.

Replace the controller's inline list DOM construction with the helper and call
it after selecting, creating, deleting, or refreshing a conversation so the
active state stays accurate. Add `handleComposerKeydown`: if the helper returns
true, prevent default and call `event.currentTarget.form.requestSubmit()`.
Add `autosizeComposer`: reset height to `auto`, then set it to the smaller of
`scrollHeight` and 160 px. Reset the inline height after a successful submit.

- [x] **Step 4: Apply the approved visual hierarchy in ERB and inert DOM classes**

Update the partial and `assistant_ui.js` together:

- white/zinc panel body in light mode and `#0a0a0a`/zinc surfaces in dark mode;
- compact mark and header, 40 px close target, quiet subtitle;
- dark neutral conversation rail, clear New chat action, truncated history;
- assistant messages as bordered neutral cards, user messages as subtle
  cyan-tinted cards, both with `leading-6` and robust wrapping;
- compact provider toolbar and destructive action;
- collapsed context search, visible selected disclosure cards, and semantic
  amber/rose status rows;
- one composer surface with textarea actions
  `input->assistant#autosizeComposer keydown->assistant#handleComposerKeydown`, a
  compact Send button, and the hint `Enter to send · Shift+Enter for a new line`;
- preserve every target name, form action, disabled state, live region, label,
  context option, and security disclosure string.

- [x] **Step 5: Run focused JS and Rails tests and verify GREEN**

Run: `cd web && node --test test/javascript/assistant_controller_test.mjs test/javascript/assistant_panel_size_test.mjs && bin/rails test test/integration/assistant_shell_test.rb`

Expected: all tests pass with 0 failures.

### Task 4: Build and regression verification

**Files:**
- Modify: `web/app/assets/builds/tailwind.css` (generated by the build only if tracked content changes)
- Verify: all files changed in Tasks 1–3

**Interfaces:**
- Produces: compiled CSS containing all classes used by the redesigned partial and JavaScript render helpers.

- [x] **Step 1: Build Tailwind from the changed source and templates**

Run: `cd web && bin/rails tailwindcss:build`

Expected: exit 0 and `app/assets/builds/tailwind.css` is regenerated without an error.

- [x] **Step 2: Run every Assistant JavaScript test**

Run: `cd web && node --test test/javascript/assistant_api_test.mjs test/javascript/assistant_controller_test.mjs test/javascript/assistant_panel_size_test.mjs`

Expected: 0 failing tests.

- [x] **Step 3: Run Assistant shell and end-to-end integration coverage**

Run: `cd web && bin/rails test test/integration/assistant_shell_test.rb test/integration/assistant_end_to_end_test.rb`

Expected: 0 failures and 0 errors.

- [x] **Step 4: Run the complete Rails suite**

Run: `cd web && bin/rails test`

Expected: 0 failures and 0 errors. If PostgreSQL is unavailable, report the
environmental blocker and the successful focused JavaScript/build evidence;
do not claim the Rails suite passes.

- [x] **Step 5: Inspect the final diff for scope and protected user changes**

Run: `git diff --check && git diff -- docs/superpowers/specs/2026-08-01-assistant-chat-ui-redesign.md docs/superpowers/plans/2026-08-01-assistant-chat-ui-redesign.md web/app/views/layouts/_assistant.html.erb web/app/javascript/controllers/assistant_controller.js web/app/javascript/lib/assistant_ui.js web/app/javascript/lib/assistant_panel_size.js web/app/assets/tailwind/application.css web/test/javascript/assistant_controller_test.mjs web/test/javascript/assistant_panel_size_test.mjs web/test/integration/assistant_shell_test.rb`

Expected: no whitespace errors, no capability-copy regression, no unrelated
files, no local-storage content beyond numeric dimensions, and no commit.
