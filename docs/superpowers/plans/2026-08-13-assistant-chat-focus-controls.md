# Assistant Chat Focus Controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the message workspace priority with a persistent collapsible history rail and safe compact/copy controls on fenced Markdown code blocks.

**Architecture:** Two small pure browser modules own the closed local-storage preference and sanitized code-block decoration. The existing Stimulus controller coordinates DOM state and clipboard status; the Rails template and namespaced CSS provide responsive layout without storing conversation data in the browser.

**Tech Stack:** Rails 8 ERB, Stimulus, importmap, Tailwind CSS v4, Marked 18.0.9, DOMPurify 3.4.13, Node test runner, JSDOM.

## Global Constraints

- History preference schema is exactly `{ "collapsed": boolean }` at `hunter:assistant-history-rail:v1`; malformed or extra-key data falls back to expanded.
- No title, conversation ID, message, provider, or other user data enters local storage.
- Long fenced blocks start compact at more than 12 logical lines; short fenced blocks and inline code remain expanded/unmodified.
- Copy code writes the complete plain code text even while compact; no generated HTML is copied.
- DOM decoration happens only after DOMPurify returns a `DocumentFragment`, using DOM APIs and `textContent`; no parser output is assigned with `innerHTML`.
- Mobile history is dismissible; desktop history collapses to a narrow rail containing New Chat and Expand controls.
- All controls remain keyboard accessible and report clipboard outcomes through the existing polite status region.

---

### Task 1: Closed history-rail preference

**Files:**
- Create: `web/app/javascript/lib/assistant_history_rail.js`
- Create: `web/test/javascript/assistant_history_rail_test.mjs`

**Interfaces:**
- Produces: `loadHistoryRailCollapsed(storage): boolean`
- Produces: `saveHistoryRailCollapsed(storage, collapsed): void`

- [ ] **Step 1: Write the failing preference tests**

```js
test("history rail accepts only one boolean field", () => {
  assert.equal(loadHistoryRailCollapsed(store('{"collapsed":true}')), true)
  for (const raw of [null, "{}", '{"collapsed":1}', '{"collapsed":true,"id":7}', "bad"]) {
    assert.equal(loadHistoryRailCollapsed(store(raw)), false)
  }
})

test("history rail persists only the closed boolean shape", () => {
  const storage = recordingStorage()
  saveHistoryRailCollapsed(storage, true)
  assert.deepEqual(JSON.parse(storage.value), { collapsed: true })
})
```

- [ ] **Step 2: Run the test and verify RED**

Run: `cd web && node --test test/javascript/assistant_history_rail_test.mjs`

Expected: FAIL because `assistant_history_rail.js` does not exist.

- [ ] **Step 3: Implement the closed parser/writer**

```js
const STORAGE_KEY = "hunter:assistant-history-rail:v1"

export function loadHistoryRailCollapsed(storage) {
  try {
    const value = JSON.parse(storage?.getItem(STORAGE_KEY))
    if (!value || Object.keys(value).sort().join() !== "collapsed") return false
    return typeof value.collapsed === "boolean" ? value.collapsed : false
  } catch { return false }
}

export function saveHistoryRailCollapsed(storage, collapsed) {
  try { storage?.setItem(STORAGE_KEY, JSON.stringify({ collapsed: collapsed === true })) } catch {}
}
```

- [ ] **Step 4: Run the test and verify GREEN**

Run: `cd web && node --test test/javascript/assistant_history_rail_test.mjs`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web/app/javascript/lib/assistant_history_rail.js web/test/javascript/assistant_history_rail_test.mjs
git commit -m "Add the closed Assistant history rail preference"
```

### Task 2: Responsive history collapse controller and markup

**Files:**
- Modify: `web/app/javascript/controllers/assistant_controller.js`
- Modify: `web/app/views/layouts/_assistant.html.erb`
- Modify: `web/app/assets/tailwind/application.css`
- Modify: `web/test/javascript/assistant_stimulus_controller_test.mjs`

**Interfaces:**
- Consumes: `loadHistoryRailCollapsed(window.localStorage)` and `saveHistoryRailCollapsed(...)`
- Produces: Stimulus action `toggleHistory(event)` and `applyHistoryState()`
- Produces: `data-history-collapsed="true|false"` on `historyWorkspaceTarget`

- [ ] **Step 1: Add a failing Stimulus behavior test**

Extend the fixture with `historyWorkspace`, `historySidebar`, `historyToggle`, and
`historyToggleLabel` targets. Then assert the user-visible behavior:

```js
test("history toggle gives the chat width and persists the preference", async () => {
  const { application, controller } = await harness()
  controller.historyCollapsed = false
  controller.applyHistoryState()

  controller.toggleHistory({ preventDefault() {} })

  assert.equal(controller.historyWorkspaceTarget.dataset.historyCollapsed, "true")
  assert.equal(controller.historyToggleTarget.getAttribute("aria-expanded"), "false")
  assert.match(controller.historyToggleTarget.getAttribute("aria-label"), /expand/i)
  assert.deepEqual(JSON.parse(window.localStorage.getItem("hunter:assistant-history-rail:v1")), {
    collapsed: true,
  })
  application.stop()
})
```

- [ ] **Step 2: Run the Stimulus test and verify RED**

Run: `cd web && node --test test/javascript/assistant_stimulus_controller_test.mjs`

Expected: FAIL because the history targets/actions do not exist.

- [ ] **Step 3: Implement controller state and actions**

Import the preference helpers, add the four targets, initialize
`this.historyCollapsed` in `connect`, and implement:

```js
toggleHistory(event) {
  event?.preventDefault()
  this.historyCollapsed = !this.historyCollapsed
  saveHistoryRailCollapsed(this.panelStorage(), this.historyCollapsed)
  this.applyHistoryState()
}

applyHistoryState() {
  const collapsed = this.historyCollapsed === true
  this.historyWorkspaceTarget.dataset.historyCollapsed = String(collapsed)
  this.historyToggleTarget.setAttribute("aria-expanded", String(!collapsed))
  this.historyToggleTarget.setAttribute("aria-label", collapsed ? "Expand conversation history" : "Collapse conversation history")
  this.historyToggleLabelTarget.textContent = collapsed ? "Expand" : "Collapse"
}
```

Load the preference before the first `applyHistoryState()` call in `connect`.

- [ ] **Step 4: Add semantic rail controls and responsive layout**

Change the workspace wrapper to `assistant-workspace-grid` with the target and
state attribute. Add a labelled toggle in the sidebar header and retain an icon
inside New Chat when its visible label is hidden. Add namespaced CSS:

```css
.assistant-workspace-grid { grid-template-columns: 7.5rem minmax(0, 1fr); }
.assistant-workspace-grid[data-history-collapsed="true"] { grid-template-columns: 3.25rem minmax(0, 1fr); }
.assistant-workspace-grid[data-history-collapsed="true"] [data-history-expanded-only] { display: none; }
@media (min-width: 640px) {
  .assistant-workspace-grid { grid-template-columns: 10.5rem minmax(0, 1fr); }
}
```

On small screens the sidebar overlays the main column when expanded and returns
to the narrow rail when collapsed. Ensure the toggle is always reachable.

- [ ] **Step 5: Run focused tests and Tailwind build**

Run:

```bash
cd web
node --test test/javascript/assistant_history_rail_test.mjs test/javascript/assistant_stimulus_controller_test.mjs
bin/rails tailwindcss:build
```

Expected: all focused tests pass and Tailwind exits 0.

- [ ] **Step 6: Commit**

```bash
git add web/app/javascript/controllers/assistant_controller.js web/app/views/layouts/_assistant.html.erb web/app/assets/tailwind/application.css web/test/javascript/assistant_stimulus_controller_test.mjs
git commit -m "Make Assistant conversation history collapsible"
```

### Task 3: Safe compact fenced-code decorator

**Files:**
- Create: `web/app/javascript/lib/assistant_code_blocks.js`
- Create: `web/test/javascript/assistant_code_blocks_test.mjs`
- Modify: `web/app/javascript/lib/assistant_markdown.js`
- Modify: `web/test/javascript/assistant_markdown_test.mjs`

**Interfaces:**
- Produces: `decorateCodeBlocks(documentRef, root, { onCopy }): HTMLElement[]`
- Produces: `normalizeCodeLanguage(value): string`
- Consumes: sanitized `root` whose code is already inert text.

- [ ] **Step 1: Write failing decorator tests against real JSDOM**

```js
test("long fenced code starts compact and copies the complete source", () => {
  const root = renderMarkdown("```ruby\n" + Array.from({ length: 13 }, (_, i) => `puts ${i}`).join("\n") + "\n```")
  const copied = []
  decorateCodeBlocks(document, root, { onCopy: (text) => copied.push(text) })

  const block = root.querySelector(".assistant-code-block")
  assert.equal(block.dataset.compact, "true")
  block.querySelector('[data-code-action="copy"]').click()
  assert.match(copied[0], /puts 12/)
  block.querySelector('[data-code-action="compact"]').click()
  assert.equal(block.dataset.compact, "false")
})

test("short fenced code stays expanded and inline code is untouched", () => {
  const root = renderMarkdown("Use `inline`\n\n```js\nconst x = 1\n```")
  decorateCodeBlocks(document, root)
  assert.equal(root.querySelector(".assistant-code-block").dataset.compact, "false")
  assert.equal(root.querySelector("p code").closest(".assistant-code-block"), null)
})
```

Also assert a malicious language string is normalized to `Code`, toolbar text
contains no parsed element, and calling the decorator twice creates one toolbar.

- [ ] **Step 2: Run tests and verify RED**

Run: `cd web && node --test test/javascript/assistant_code_blocks_test.mjs`

Expected: FAIL because the decorator module does not exist.

- [ ] **Step 3: Implement deterministic decoration**

Use a line threshold of 12. Normalize languages with
`/\A[a-z0-9_+.#-]{1,24}\z/i` semantics in JavaScript and fall back to `Code`.
Wrap only direct `pre > code` nodes, create the toolbar/buttons with
`createElement`, set all copy sources from `code.textContent`, and toggle only
the wrapper's `data-compact` plus button text/`aria-expanded`.

- [ ] **Step 4: Preserve parser language as safe metadata**

Add a Marked `renderer.code` that emits the sanitized code text and a normalized
`title="language:<value>"` marker on the code element. The decorator consumes
and removes that marker before building the visible label. Keep `title` as the
only already-allowed attribute; do not add `class` or `data-*` to purifier input.

- [ ] **Step 5: Run Markdown/decorator tests and verify GREEN**

Run:

```bash
cd web
node --test test/javascript/assistant_markdown_test.mjs test/javascript/assistant_code_blocks_test.mjs
```

Expected: all tests pass, including the existing XSS fixtures.

- [ ] **Step 6: Commit**

```bash
git add web/app/javascript/lib/assistant_code_blocks.js web/test/javascript/assistant_code_blocks_test.mjs web/app/javascript/lib/assistant_markdown.js web/test/javascript/assistant_markdown_test.mjs
git commit -m "Add safe compact controls for Assistant code blocks"
```

### Task 4: Message integration, styling, and verification

**Files:**
- Modify: `web/app/javascript/lib/assistant_ui.js`
- Modify: `web/app/javascript/controllers/assistant_controller.js`
- Modify: `web/app/assets/tailwind/application.css`
- Modify: `web/test/javascript/assistant_controller_test.mjs`
- Modify: `web/test/javascript/assistant_stimulus_controller_test.mjs`
- Modify: `docs/superpowers/specs/2026-08-13-assistant-direct-provider-selection-design.md`

**Interfaces:**
- Consumes: `decorateCodeBlocks(..., { onCopy })`
- Produces: controller `copyCode(text): Promise<void>`

- [ ] **Step 1: Add failing message integration tests**

Assert `appendMessage` produces one compact code toolbar only for fenced code,
the callback receives the complete code string, and an Assistant controller
clipboard rejection reports “The code could not be copied.” without throwing.

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
cd web
node --test test/javascript/assistant_controller_test.mjs test/javascript/assistant_stimulus_controller_test.mjs
```

Expected: FAIL because messages do not decorate blocks or route code copy.

- [ ] **Step 3: Integrate decoration and clipboard status**

After appending the sanitized fragment in `appendMessage`, call
`decorateCodeBlocks(documentRef, body, { onCopy: callbacks.onCopyCode })`.
Pass `onCopyCode: (text) => this.copyCode(text)` from the controller and use the
existing Clipboard API/status pattern with code-specific messages.

- [ ] **Step 4: Add namespaced compact styles**

Style `.assistant-code-block`, its toolbar, scrollable `pre`, and
`[data-compact="true"] pre` with a maximum height and bottom fade/overflow cue.
Preserve wrapping and horizontal scrolling semantics for code text.

- [ ] **Step 5: Run the complete browser suite and static build**

Run:

```bash
cd web
node --test test/javascript/*.mjs
bin/rails tailwindcss:build
git diff --check
```

Expected: all JavaScript tests pass, Tailwind exits 0, and diff check is clean.

- [ ] **Step 6: Record completion evidence and commit**

Update the design status/evidence for this subsystem without marking the larger
dual-provider feature complete.

```bash
git add web/app/javascript/lib/assistant_ui.js web/app/javascript/controllers/assistant_controller.js web/app/assets/tailwind/application.css web/test/javascript/assistant_controller_test.mjs web/test/javascript/assistant_stimulus_controller_test.mjs docs/superpowers/specs/2026-08-13-assistant-direct-provider-selection-design.md
git commit -m "Complete Assistant chat focus controls"
```

