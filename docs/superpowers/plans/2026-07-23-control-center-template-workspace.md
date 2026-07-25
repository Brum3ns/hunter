# Control Center Template Workspace and Dork Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the Whiterabbit template editor visible above an independently scrolling, dork-searchable template library with row selection and unsaved-change protection.

**Architecture:** Two DOM-independent ES modules own query parsing/evaluation and editor-session state. The existing Templates Stimulus controller caches the API index, coordinates those modules with the editor and table, and preserves the current Rails JSON API; ERB supplies a viewport workspace, search/help controls, permanent editor, and accessible list states.

**Tech Stack:** Rails 8.1, ERB, Tailwind CSS v4, importmap-rails, Stimulus, CodeMirror, Node 24 built-in `node:test`, Minitest integration tests.

## Global Constraints

- On desktop, render the editor above a separately scrolling library inside a viewport-bounded workspace; use normal vertical flow on small screens.
- Initialize the permanent editor as a blank, editable `cmdscript` with one empty command row.
- Clicking or keyboard-activating a row selects it; **Send**, **Edit**, and **Delete** must not bubble into row selection.
- Prompt before replacing dirty editor contents from a different row, **New template**, or **Cancel**; declining must preserve the current editor and selection.
- **Save** keeps the returned template selected; **Save & close** and **Cancel** reset to clean blank creation state without hiding the editor.
- Search is client-side over the last good index response and supports plain text, `name:`, `kind:`, `tag:`, `command:`, `creator:`, implicit AND, explicit AND/OR, parentheses, quotes, and `*` wildcards.
- Unknown dorks become literal text; malformed search input must degrade safely without throwing.
- Filtering, refresh, Send, and completed bulk import must never replace editor contents.
- Preserve the existing bulk import, drag/drop, conflict dialog, YAML upload/download, validation, editor modes, and JSON API contracts.
- Add no route, migration, API action, pagination behavior, or dependency.
- Insert template- and query-derived content with `textContent`, never `innerHTML`.
- Do not modify `web/config/routes.rb`, `ControlCenter::BaseController::TABS`, or `web/test/integration/control_center/tabs_test.rb`; another contributor is changing a separate Control Center tab.
- Before every patch, inspect `git status --short` and preserve all unrelated shared-worktree changes, especially Control Center Ansible files and documentation.
- Do not commit unless the user explicitly requests a commit. Replace plan commit steps with review checkpoints.

## File Structure

- Create `web/app/javascript/lib/template_search.js`: pure tokenizer, parser, evaluator, and stable filter.
- Create `web/test/javascript/template_search_test.mjs`: Node behavior coverage for the full query language.
- Create `web/app/javascript/lib/template_editor_session.js`: pure selected-ID and dirty-state transitions.
- Create `web/test/javascript/template_editor_session_test.mjs`: Node coverage for clean, dirty, switch, save, and reset decisions.
- Modify `web/app/views/control_center/templates/index.html.erb`: permanent top editor, desktop pane layout, search/help toolbar, list states, and modal Send presentation.
- Modify `web/app/javascript/controllers/control_center_templates_controller.js`: cached filtering, list failures, row selection, editor guarding, dirty wiring, and permanent editor behavior.
- Create `web/test/integration/control_center/template_workspace_test.rb`: authenticated markup contract isolated from the shared tab test and existing bulk-import test.
- Update `docs/superpowers/specs/2026-07-23-control-center-template-workspace-design.md`: mark implemented only after all required automated and browser checks pass.

---

### Task 1: Pure template dork parser and evaluator

**Files:**
- Create: `web/test/javascript/template_search_test.mjs`
- Create: `web/app/javascript/lib/template_search.js`

**Interfaces:**
- Produces: `parseTemplateQuery(query: unknown) -> Expression | null`.
- Produces: `filterTemplates(templates: Array<object>, query: unknown) -> Array<object>`.
- `Expression` nodes are `{ type: "term", key: String | null, value: String }` or `{ type: "and" | "or", children: Expression[] }`.
- Filtering preserves API order and returns a new array without changing template objects.

- [ ] **Step 1: Recheck the shared worktree before creating test files**

Run from the repository root:

```bash
git status --short
git diff -- web/app/javascript/controllers/control_center_templates_controller.js web/app/views/control_center/templates/index.html.erb
```

Expected: bulk-import and icon fixes remain present; no unrelated contributor changes are overwritten.

- [ ] **Step 2: Write the failing query-language tests**

Create `web/test/javascript/template_search_test.mjs`:

```javascript
import test from "node:test"
import assert from "node:assert/strict"
import { filterTemplates, parseTemplateQuery } from "../../app/javascript/lib/template_search.js"

const templates = [
  {
    id: 1,
    name: "nuclei-cve",
    kind: "cmdscript",
    description: "Scan remote code execution signatures",
    tags: ["cve", "network"],
    created_by: "alice",
    commands: [{ command: "nuclei", args: ["-tags", "cve"] }],
  },
  {
    id: 2,
    name: "http-probe",
    kind: "workflow",
    description: "owner:alice compatibility probe",
    tags: ["http"],
    created_by: "bob",
    commands: [{ command: "httpx", args: [["-silent"], ["-status-code"]] }],
  },
  {
    id: 3,
    name: "dns-enum",
    kind: "cmdscript",
    description: "Enumerate DNS records",
    tags: ["network"],
    created_by: "carol",
    commands: [{ command: "dnsx", args: ["-resp"] }],
  },
]

const ids = (query) => filterTemplates(templates, query).map((template) => template.id)

test("plain text searches names, descriptions, tags, commands, and arguments", () => {
  assert.deepEqual(ids("nuclei"), [1])
  assert.deepEqual(ids("remote code"), [1])
  assert.deepEqual(ids("network"), [1, 3])
  assert.deepEqual(ids("httpx"), [2])
  assert.deepEqual(ids("status-code"), [2])
})

test("supported dorks use their documented matching semantics", () => {
  assert.deepEqual(ids("name:cve"), [1])
  assert.deepEqual(ids("name:http-*"), [2])
  assert.deepEqual(ids("kind:workflow"), [2])
  assert.deepEqual(ids("tag:network"), [1, 3])
  assert.deepEqual(ids("command:nuclei"), [1])
  assert.deepEqual(ids('command:"httpx -silent"'), [2])
  assert.deepEqual(ids("creator:ALICE"), [1])
})

test("AND binds tighter than OR and parentheses override precedence", () => {
  assert.deepEqual(ids("tag:cve OR tag:http AND kind:cmdscript"), [1])
  assert.deepEqual(ids("(tag:cve OR tag:http) AND kind:cmdscript"), [1])
  assert.deepEqual(ids("kind:cmdscript tag:network"), [1, 3])
  assert.deepEqual(ids("kind:workflow OR creator:carol"), [2, 3])
})

test("quotes, case folding, and escaped wildcard input are safe", () => {
  assert.deepEqual(ids('"remote code"'), [1])
  assert.deepEqual(ids("NAME:NUCLEI-*"), [1])
  assert.deepEqual(ids("name:*probe"), [2])
  assert.doesNotThrow(() => ids("name:[*"))
})

test("unknown dorks remain literal text", () => {
  assert.deepEqual(ids("owner:alice"), [2])
})

test("malformed expressions fall back without throwing", () => {
  for (const query of ['name:"nuclei', "(tag:cve", "tag:cve OR", "AND tag:cve"]) {
    assert.doesNotThrow(() => filterTemplates(templates, query), query)
  }
})

test("blank filtering preserves order without mutating the source array", () => {
  const original = [...templates]
  const result = filterTemplates(templates, "")
  assert.deepEqual(result.map((template) => template.id), [1, 2, 3])
  assert.notEqual(result, templates)
  assert.deepEqual(templates, original)
})

test("the parser exposes a stable expression shape", () => {
  assert.deepEqual(parseTemplateQuery("name:nuclei tag:cve OR creator:bob"), {
    type: "or",
    children: [
      {
        type: "and",
        children: [
          { type: "term", key: "name", value: "nuclei" },
          { type: "term", key: "tag", value: "cve" },
        ],
      },
      { type: "term", key: "creator", value: "bob" },
    ],
  })
})
```

- [ ] **Step 3: Run the focused test and verify RED**

Run from `web/`:

```bash
node --test test/javascript/template_search_test.mjs
```

Expected: FAIL with `ERR_MODULE_NOT_FOUND` for `app/javascript/lib/template_search.js`.

- [ ] **Step 4: Implement the tokenizer, parser, and evaluator**

Create `web/app/javascript/lib/template_search.js`:

```javascript
const DORK_KEYS = new Set(["name", "kind", "tag", "command", "creator"])

export function parseTemplateQuery(query) {
  const raw = String(query || "").trim()
  if (!raw) return null
  try {
    return new QueryParser(tokenize(raw)).parse()
  } catch {
    return fallbackExpression(raw)
  }
}

export function filterTemplates(templates, query) {
  const source = Array.from(templates || [])
  const expression = parseTemplateQuery(query)
  return expression ? source.filter((template) => evaluate(expression, template || {})) : source
}

function tokenize(input) {
  const tokens = []
  let index = 0
  while (index < input.length) {
    if (/\s/.test(input[index])) { index += 1; continue }
    if (input[index] === "(") { tokens.push({ type: "lparen" }); index += 1; continue }
    if (input[index] === ")") { tokens.push({ type: "rparen" }); index += 1; continue }

    let value = ""
    while (index < input.length && !/\s|[()]/.test(input[index])) {
      if (input[index] !== '"') { value += input[index]; index += 1; continue }
      index += 1
      let closed = false
      while (index < input.length) {
        if (input[index] === "\\" && index + 1 < input.length) {
          value += input[index + 1]; index += 2
        } else if (input[index] === '"') {
          closed = true; index += 1; break
        } else {
          value += input[index]; index += 1
        }
      }
      if (!closed) throw new SyntaxError("unterminated quote")
    }

    if (!value) continue
    const operator = value.toUpperCase()
    if (operator === "AND" || operator === "OR") {
      tokens.push({ type: operator.toLowerCase() })
      continue
    }
    const colon = value.indexOf(":")
    const candidate = colon > 0 ? value.slice(0, colon).toLowerCase() : null
    const dorkValue = colon > 0 ? value.slice(colon + 1) : ""
    tokens.push(candidate && DORK_KEYS.has(candidate) && dorkValue
      ? { type: "term", key: candidate, value: dorkValue }
      : { type: "term", key: null, value })
  }
  return tokens
}

class QueryParser {
  constructor(tokens) { this.tokens = tokens; this.position = 0 }

  parse() {
    const expression = this.parseOr()
    if (!expression || this.position !== this.tokens.length) throw new SyntaxError("invalid expression")
    return expression
  }

  parseOr() {
    const children = [this.parseAnd()]
    while (this.peek()?.type === "or") { this.position += 1; children.push(this.parseAnd()) }
    return combine("or", children)
  }

  parseAnd() {
    const children = [this.parsePrimary()]
    while (true) {
      const type = this.peek()?.type
      if (type === "and") { this.position += 1; children.push(this.parsePrimary()) }
      else if (type === "term" || type === "lparen") children.push(this.parsePrimary())
      else break
    }
    return combine("and", children)
  }

  parsePrimary() {
    const token = this.peek()
    if (!token) throw new SyntaxError("missing operand")
    if (token.type === "term") {
      this.position += 1
      return { type: "term", key: token.key, value: token.value }
    }
    if (token.type === "lparen") {
      this.position += 1
      const expression = this.parseOr()
      if (this.peek()?.type !== "rparen") throw new SyntaxError("unmatched parenthesis")
      this.position += 1
      return expression
    }
    throw new SyntaxError("unexpected token")
  }

  peek() { return this.tokens[this.position] }
}

function combine(type, children) {
  if (children.some((child) => !child)) throw new SyntaxError("missing operand")
  return children.length === 1 ? children[0] : { type, children }
}

function fallbackExpression(raw) {
  const words = raw.replace(/[()]/g, " ").replace(/"/g, "").split(/\s+/)
    .filter((word) => word && !/^(?:AND|OR)$/i.test(word))
    .map((value) => ({ type: "term", key: null, value }))
  return words.length ? combine("and", words) : null
}

function evaluate(expression, template) {
  if (expression.type === "and") return expression.children.every((child) => evaluate(child, template))
  if (expression.type === "or") return expression.children.some((child) => evaluate(child, template))
  return matchesTerm(template, expression)
}

function matchesTerm(template, term) {
  const commandValues = Array.from(template.commands || []).flatMap((command) => {
    const args = flatten(command?.args)
    const executable = String(command?.command || "")
    return [executable, ...args, [executable, ...args].join(" ")]
  })
  if (!term.key) {
    return [template.name, template.description, ...(template.tags || []), ...commandValues]
      .some((value) => matchValue(value, term.value, false))
  }
  const fields = {
    name: [template.name], kind: [template.kind], tag: template.tags || [],
    command: commandValues, creator: [template.created_by],
  }
  const exact = ["kind", "tag", "creator"].includes(term.key)
  return fields[term.key].some((value) => matchValue(value, term.value, exact))
}

function flatten(value) {
  if (!Array.isArray(value)) return value == null ? [] : [String(value)]
  return value.flatMap((entry) => flatten(entry))
}

function matchValue(actualValue, queryValue, exact) {
  const actual = String(actualValue || "").toLowerCase()
  const wanted = String(queryValue || "").toLowerCase()
  if (!wanted) return false
  if (!wanted.includes("*")) return exact ? actual === wanted : actual.includes(wanted)
  const source = wanted.split("*")
    .map((part) => part.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"))
    .join(".*")
  return new RegExp(`^${source}$`, "i").test(actual)
}
```

- [ ] **Step 5: Run the query tests and verify GREEN**

Run:

```bash
node --test test/javascript/template_search_test.mjs
node --check app/javascript/lib/template_search.js
```

Expected: 8 tests pass, 0 fail; syntax check exits 0.

- [ ] **Step 6: Review checkpoint without committing**

Run:

```bash
git diff --check
git diff -- web/app/javascript/lib/template_search.js web/test/javascript/template_search_test.mjs
```

Expected: no whitespace errors; diff contains only the pure search module and its focused test.

---

### Task 2: Pure editor-session state

**Files:**
- Create: `web/test/javascript/template_editor_session_test.mjs`
- Create: `web/app/javascript/lib/template_editor_session.js`

**Interfaces:**
- Produces: `new TemplateEditorSession()` with `editingId`, `dirty`, `markDirty()`, `markClean(editingId)`, `isEditing(editingId)`, and `mayReplace(confirmDiscard)`.
- `mayReplace` returns `true` immediately when clean and otherwise returns the boolean result of `confirmDiscard()` without mutating state.

- [ ] **Step 1: Recheck shared-worktree status**

Run: `git status --short`

Expected: Task 1 files plus pre-existing work; no unexpected overlap with contributor-owned files.

- [ ] **Step 2: Write the failing state-machine tests**

Create `web/test/javascript/template_editor_session_test.mjs`:

```javascript
import test from "node:test"
import assert from "node:assert/strict"
import { TemplateEditorSession } from "../../app/javascript/lib/template_editor_session.js"

test("starts as a clean blank editor", () => {
  const session = new TemplateEditorSession()
  assert.equal(session.editingId, null)
  assert.equal(session.dirty, false)
  assert.equal(session.isEditing(1), false)
})

test("markDirty requires confirmation before replacement", () => {
  const session = new TemplateEditorSession()
  session.markDirty()
  let prompts = 0
  assert.equal(session.mayReplace(() => { prompts += 1; return false }), false)
  assert.equal(session.dirty, true)
  assert.equal(session.mayReplace(() => { prompts += 1; return true }), true)
  assert.equal(session.dirty, true)
  assert.equal(prompts, 2)
})

test("clean sessions replace without invoking confirmation", () => {
  const session = new TemplateEditorSession()
  session.markClean(12)
  assert.equal(session.mayReplace(() => { throw new Error("must not prompt") }), true)
  assert.equal(session.isEditing("12"), true)
})

test("save and reset establish new clean identities", () => {
  const session = new TemplateEditorSession()
  session.markDirty()
  session.markClean(42)
  assert.equal(session.editingId, 42)
  assert.equal(session.dirty, false)
  session.markDirty()
  session.markClean(null)
  assert.equal(session.editingId, null)
  assert.equal(session.dirty, false)
})
```

- [ ] **Step 3: Run the test and verify RED**

Run: `node --test test/javascript/template_editor_session_test.mjs`

Expected: FAIL with `ERR_MODULE_NOT_FOUND` for `template_editor_session.js`.

- [ ] **Step 4: Implement the session state**

Create `web/app/javascript/lib/template_editor_session.js`:

```javascript
export class TemplateEditorSession {
  constructor() {
    this.editingId = null
    this.dirty = false
  }

  markDirty() { this.dirty = true }

  markClean(editingId = null) {
    this.editingId = editingId ?? null
    this.dirty = false
  }

  isEditing(editingId) {
    return this.editingId !== null && editingId !== null && String(this.editingId) === String(editingId)
  }

  mayReplace(confirmDiscard) {
    return !this.dirty || Boolean(confirmDiscard())
  }
}
```

- [ ] **Step 5: Run the state tests and verify GREEN**

Run:

```bash
node --test test/javascript/template_editor_session_test.mjs
node --check app/javascript/lib/template_editor_session.js
```

Expected: 4 tests pass, 0 fail; syntax check exits 0.

- [ ] **Step 6: Review checkpoint without committing**

Run:

```bash
git diff --check
git diff -- web/app/javascript/lib/template_editor_session.js web/test/javascript/template_editor_session_test.mjs
```

Expected: no whitespace errors; module has no DOM or browser dependency.

---

### Task 3: Permanent editor and searchable library markup

**Files:**
- Create: `web/test/integration/control_center/template_workspace_test.rb`
- Modify: `web/app/views/control_center/templates/index.html.erb`

**Interfaces:**
- Produces Stimulus targets: `searchInput`, `resultCount`, `clearSearch`, `listError`, and `noMatches`, plus all existing targets.
- Produces stable layout markers: `data-template-workspace`, `data-template-editor-pane`, `data-template-library-pane`, and `data-template-library-scroll`.
- Search actions are `input->control-center-templates#searchChanged`, `search->control-center-templates#searchChanged`, and `control-center-templates#clearSearch`.
- The editor root adds bubbling `input->control-center-templates#markEditorDirty` and `change->control-center-templates#markEditorDirty` actions.

- [ ] **Step 1: Recheck the view diff before editing the shared file**

Run:

```bash
git status --short
git diff -- web/app/views/control_center/templates/index.html.erb
```

Expected: the approved bulk-import markup remains visible in the diff; preserve it verbatim.

- [ ] **Step 2: Write the failing authenticated markup contract**

Create `web/test/integration/control_center/template_workspace_test.rb`:

```ruby
require "test_helper"

class ControlCenter::TemplateWorkspaceTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:one))
    get control_center_root_path
  end

  test "renders a permanent editor above a separately scrolling library" do
    assert_response :success
    assert_select "[data-template-workspace]" do
      assert_select "[data-template-editor-pane][data-control-center-templates-target=editor]:not(.hidden)", count: 1
      assert_select "[data-template-library-pane]", count: 1
      assert_select "[data-template-library-scroll]", count: 1
    end
    assert_operator response.body.index("data-template-editor-pane"), :<,
                    response.body.index("data-template-library-pane")
  end

  test "renders template dork search controls and distinct list states" do
    assert_select "input[type=search][data-control-center-templates-target=searchInput]" do |inputs|
      actions = inputs.first["data-action"].split
      assert_includes actions, "input->control-center-templates#searchChanged"
      assert_includes actions, "search->control-center-templates#searchChanged"
    end
    assert_select "button[data-control-center-templates-target=clearSearch][data-action='control-center-templates#clearSearch']"
    assert_select "[data-control-center-templates-target=resultCount]"
    assert_select "[data-control-center-templates-target=listError]"
    assert_select "[data-control-center-templates-target=empty]", text: /No templates yet/
    assert_select "[data-control-center-templates-target=noMatches]", text: /No templates match/
    assert_select "button[aria-label='Template search syntax help']"
  end

  test "wires editor-wide dirty tracking without hiding the editor" do
    editor = css_select("[data-control-center-templates-target=editor]").first
    refute_nil editor
    refute_includes editor["class"].split, "hidden"
    actions = editor["data-action"].split
    assert_includes actions, "input->control-center-templates#markEditorDirty"
    assert_includes actions, "change->control-center-templates#markEditorDirty"
  end
end
```

- [ ] **Step 3: Run the focused integration test and verify RED**

Run from `web/` with the reachable Hunter test database:

```bash
DB_HOST=localhost DB_PORT=5433 DB_DATABASE_TEST=hunter_test RAILS_ENV=test /opt/rbenv/shims/bundle exec rails test test/integration/control_center/template_workspace_test.rb
```

Expected: FAIL because the workspace markers and search targets do not exist and the editor still has `hidden`.

If PostgreSQL is unavailable, record the connection error as an environment blocker, then run this syntax-only fallback:

```bash
/opt/rbenv/shims/ruby -c test/integration/control_center/template_workspace_test.rb
```

Expected fallback: `Syntax OK`; this does not replace the required red test once PostgreSQL is reachable.

- [ ] **Step 4: Add dork-help data and the desktop workspace wrapper**

After the existing `content_for` calls, add:

```erb
<%
  template_dork_groups = [
    ["Fields", [
      ["name:nuclei-*", "template name"],
      ["kind:cmdscript", "cmdscript or workflow"],
      ["tag:cve", "exact tag"],
      ["command:nuclei", "executable or arguments"],
      ["creator:alice", "creator username"]
    ]],
    ["Combine", [
      ["a b", "implicit AND"],
      ["a AND b", "both match"],
      ["a OR b", "either matches"],
      ["(a OR b) AND c", "group with parentheses"],
      ['command:"httpx -silent"', "quote values containing spaces"]
    ]]
  ]
%>
```

Replace the opening Templates `<section>` tag with this exact tag, retaining every existing URL value and drag action:

```erb
<section class="mt-6 lg:grid lg:h-[calc(100dvh-12rem)] lg:min-h-[40rem] lg:grid-rows-[minmax(18rem,1fr)_minmax(14rem,1fr)] lg:gap-4 lg:overflow-hidden"
         data-template-workspace
         data-controller="control-center-templates"
         data-action="dragenter@window->control-center-templates#dragEnter dragover@window->control-center-templates#dragOver dragleave@window->control-center-templates#dragLeave drop@window->control-center-templates#dropFiles dragend@window->control-center-templates#dragEnd"
         data-control-center-templates-index-url-value="<%= api_v1_control_center_templates_path %>"
         data-control-center-templates-validate-url-value="<%= validate_api_v1_control_center_templates_path %>"
         data-control-center-templates-jobs-url-value="<%= api_v1_control_center_jobs_path %>"
         data-control-center-templates-validate-yaml-url-value="<%= validate_yaml_api_v1_control_center_templates_path %>">
```

- [ ] **Step 5: Move and adapt the existing editor block**

Relocate the complete existing block beginning with
`<div data-control-center-templates-target="editor"` and ending immediately
before the send-job dialog so it is the first child inside the section. Its
fields, command-row template, mode buttons, upload/download controls, validation
targets, and save actions remain byte-for-byte unchanged in this relocation.

Replace its opening element with:

```erb
<div data-template-editor-pane
     data-control-center-templates-target="editor"
     data-action="input->control-center-templates#markEditorDirty change->control-center-templates#markEditorDirty"
     class="slim-scroll rounded-lg border border-zinc-200 bg-white p-4 dark:border-zinc-800 dark:bg-[#111315] lg:min-h-0 lg:overflow-y-auto">
```

Replace the editor's first toolbar opening element with:

```erb
<div class="sticky top-0 z-10 mb-3 flex items-center gap-2 bg-white pb-3 dark:bg-[#111315]">
```

Expected: the editor has no `hidden` or `mt-4`, and remains above the library in source and visual order.

- [ ] **Step 6: Add the library pane and search toolbar**

Wrap the current Refresh/Import/New toolbar, table, and list empty state in:

```erb
<div data-template-library-pane class="mt-4 flex min-h-0 flex-col lg:mt-0">
```

Insert this search block as its first child:

```erb
<div class="shrink-0 rounded-t-lg border border-b-0 border-zinc-200 bg-white p-3 dark:border-zinc-800 dark:bg-[#111315]">
  <div class="flex flex-wrap items-center gap-2">
    <div class="relative min-w-[16rem] flex-1">
      <label for="template-search" class="sr-only">Search templates</label>
      <input id="template-search" type="search" autocomplete="off"
             placeholder="Search or dork… name:nuclei-* tag:cve"
             data-control-center-templates-target="searchInput"
             data-action="input->control-center-templates#searchChanged search->control-center-templates#searchChanged"
             class="w-full rounded-md border border-zinc-300 bg-white py-2 pl-3 pr-10 text-sm text-zinc-900 placeholder:text-zinc-400 focus:border-zinc-900 focus:outline-none dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-100 dark:focus:border-zinc-300">
      <div class="group absolute right-1.5 top-1/2 -translate-y-1/2">
        <button type="button" aria-label="Template search syntax help"
                class="inline-flex h-7 w-7 items-center justify-center rounded-md text-zinc-400 outline-none hover:bg-zinc-100 hover:text-zinc-700 focus:bg-zinc-100 focus:text-zinc-700 dark:hover:bg-zinc-800 dark:hover:text-zinc-200">
          <%= heroicon "question-mark-circle", classes: "h-4 w-4" %>
        </button>
        <div class="invisible absolute right-0 top-full z-40 mt-2 w-80 max-w-[calc(100vw-3rem)] rounded-md border border-zinc-200 bg-white p-3 opacity-0 shadow-xl transition-opacity group-hover:visible group-hover:opacity-100 group-focus-within:visible group-focus-within:opacity-100 dark:border-zinc-800 dark:bg-[#111315]">
          <% template_dork_groups.each_with_index do |(title, rows), index| %>
            <p class="text-[10.5px] font-medium uppercase tracking-[0.12em] text-zinc-400 <%= index.zero? ? "mb-2" : "mt-3 mb-2 border-t border-zinc-200 pt-2 dark:border-zinc-800" %>"><%= title %></p>
            <dl class="space-y-1.5 font-mono">
              <% rows.each do |dork, hint| %>
                <div>
                  <dt class="break-all text-[11.5px] text-zinc-800 dark:text-zinc-200"><%= dork %></dt>
                  <dd class="pl-3 text-[10.5px] text-zinc-500 dark:text-zinc-400"><%= hint %></dd>
                </div>
              <% end %>
            </dl>
          <% end %>
          <p class="mt-3 border-t border-zinc-200 pt-2 text-[10.5px] text-zinc-500 dark:border-zinc-800 dark:text-zinc-400">Case-insensitive · plain text searches names, descriptions, tags, commands, and arguments.</p>
        </div>
      </div>
    </div>

    <span data-control-center-templates-target="resultCount" aria-live="polite"
          class="text-xs tabular-nums text-zinc-500 dark:text-zinc-400">0 of 0 templates</span>
    <button type="button" data-control-center-templates-target="clearSearch"
            data-action="control-center-templates#clearSearch"
            class="hidden rounded-md border border-zinc-300 px-2.5 py-2 text-sm text-zinc-600 hover:bg-zinc-100 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800">Clear</button>
  </div>

  <p data-control-center-templates-target="listError" role="status" aria-live="polite"
     class="mt-2 hidden rounded-md bg-rose-50 px-3 py-2 text-xs text-rose-700 dark:bg-rose-950/40 dark:text-rose-300"></p>
</div>
```

Immediately after that block, retain the existing complete Refresh/Import/New
toolbar and replace only its opening element with:

```erb
<div class="flex flex-wrap items-center justify-between gap-2 border-x border-zinc-200 bg-white px-3 pb-3 dark:border-zinc-800 dark:bg-[#111315]">
```

The buttons, icons, multiple-file input, targets, and actions inside it do not
change.

- [ ] **Step 7: Make the table region independently scrollable**

Replace the table wrapper opening element with:

```erb
<div data-template-library-scroll class="min-h-0 flex-1 overflow-auto rounded-b-lg border border-zinc-200 bg-white slim-scroll dark:border-zinc-800 dark:bg-[#111315]">
```

Replace `<thead>` with:

```erb
<thead class="sticky top-0 z-10 border-b border-zinc-100 bg-white text-xs uppercase tracking-wide text-zinc-500 dark:border-zinc-800 dark:bg-[#111315] dark:text-zinc-400">
```

Keep the existing `empty` message and add this sibling immediately after it:

```erb
<div data-control-center-templates-target="noMatches" class="hidden px-4 py-12 text-center text-sm text-zinc-400 dark:text-zinc-500">
  No templates match this search.
</div>
```

Close `data-template-library-scroll` and `data-template-library-pane` before the
send-job dialog. Preserve the bulk-import dialog and drop overlay after the two
workspace panes.

- [ ] **Step 8: Present Send as a modal without hiding the permanent editor**

Replace the current send-job root with this opening tag, retaining all existing
form fields, targets, buttons, and body markup:

```erb
<dialog data-control-center-templates-target="sendDialog"
        class="fixed inset-0 z-50 m-auto w-[min(48rem,calc(100vw-2rem))] rounded-xl border border-zinc-200 bg-white p-4 text-zinc-900 shadow-2xl backdrop:bg-zinc-950/60 dark:border-zinc-700 dark:bg-[#111315] dark:text-zinc-100">
```

Replace the matching closing `</div>` with `</dialog>`.

- [ ] **Step 9: Run markup verification**

Run:

```bash
DB_HOST=localhost DB_PORT=5433 DB_DATABASE_TEST=hunter_test RAILS_ENV=test /opt/rbenv/shims/bundle exec rails test test/integration/control_center/template_workspace_test.rb test/integration/control_center/template_import_test.rb
/opt/rbenv/shims/erb -x -T - app/views/control_center/templates/index.html.erb | /opt/rbenv/shims/ruby -c
```

Expected: 6 focused integration tests pass, 0 fail; ERB reports `Syntax OK`.

- [ ] **Step 10: Review checkpoint without committing**

Run:

```bash
git diff --check
git diff -- web/app/views/control_center/templates/index.html.erb web/test/integration/control_center/template_workspace_test.rb
```

Expected: bulk import markup is preserved, editor precedes library, and no route/tab files changed.

---

### Task 4: Cache, filter, and activate template rows

**Files:**
- Modify: `web/app/javascript/controllers/control_center_templates_controller.js`

**Interfaces:**
- Consumes: `filterTemplates(templates, query)` from Task 1.
- Consumes: `TemplateEditorSession` from Task 2.
- Consumes: all search/layout targets from Task 3.
- Produces controller methods: `searchChanged()`, `clearSearch()`, `selectTemplate(template)`, `_confirmEditorReplacement()`, `_populateEditor(template)`, and `_resetEditor(options)`.

- [ ] **Step 1: Recheck the controller diff before editing**

Run:

```bash
git status --short
git diff -- web/app/javascript/controllers/control_center_templates_controller.js
```

Expected: preserve every batch-import method and callback added by the prior feature.

- [ ] **Step 2: Import pure modules and declare targets**

Add after the existing imports:

```javascript
import { filterTemplates } from "lib/template_search"
import { TemplateEditorSession } from "lib/template_editor_session"
```

Add these names to `static targets` without removing any existing target:

```javascript
"searchInput", "resultCount", "clearSearch", "listError", "noMatches",
```

- [ ] **Step 3: Initialize permanent blank editor and list state**

Replace `connect()` with:

```javascript
connect() {
  this.templates = []
  this.listLoaded = false
  this.editorSession = new TemplateEditorSession()
  this.sendTemplate = null
  this.mode = "structured"
  this.lastEdited = "structured"
  this._syncing = false
  this._mountEditor()
  this._dragDepth = 0
  this._importActive = false
  this._importRowViews = new Map()
  this._pendingConflict = null
  this._resetEditor({ guard: false, focus: false })
  this.refresh()
}
```

Keep `disconnect()` and add `clearTimeout(this._searchTimer)` beside its existing timers.

- [ ] **Step 4: Cache the last good list and add filtered rendering**

Replace `refresh()` and `render(templates)` with:

```javascript
async refresh() {
  const { ok, data } = await apiFetch(this.indexUrlValue)
  if (!ok || !Array.isArray(data?.templates)) {
    this.listErrorTarget.textContent = this.listLoaded
      ? "Could not refresh templates. Showing the last available list."
      : "Could not load templates."
    this.listErrorTarget.classList.remove("hidden")
    this.render()
    return false
  }

  this.templates = data.templates
  this.listLoaded = true
  this.listErrorTarget.textContent = ""
  this.listErrorTarget.classList.add("hidden")
  this.render()
  return true
}

render() {
  const query = this.searchInputTarget.value.trim()
  const filtered = filterTemplates(this.templates, query)
  this.rowsTarget.replaceChildren()
  filtered.forEach((template) => this.rowsTarget.appendChild(this.rowFor(template)))
  this.resultCountTarget.textContent = `${filtered.length} of ${this.templates.length} templates`
  this.clearSearchTarget.classList.toggle("hidden", query.length === 0)
  this.emptyTarget.classList.toggle("hidden", !this.listLoaded || this.templates.length > 0)
  this.noMatchesTarget.classList.toggle("hidden", query.length === 0 || this.templates.length === 0 || filtered.length > 0)
}

searchChanged() {
  clearTimeout(this._searchTimer)
  this._searchTimer = setTimeout(() => this.render(), 100)
}

clearSearch() {
  clearTimeout(this._searchTimer)
  this.searchInputTarget.value = ""
  this.render()
  this.searchInputTarget.focus()
}
```

- [ ] **Step 5: Make generated rows selected, clickable, and keyboard reachable**

At the start of `rowFor(t)`, after creating `tr`, add:

```javascript
tr.tabIndex = 0
tr.dataset.templateId = t.id
tr.setAttribute("aria-selected", String(this.editorSession.isEditing(t.id)))
tr.className = "cursor-pointer outline-none transition-colors hover:bg-zinc-50 focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-zinc-400 dark:hover:bg-zinc-800/50"
tr.classList.toggle("bg-zinc-100", this.editorSession.isEditing(t.id))
tr.classList.toggle("dark:bg-zinc-800", this.editorSession.isEditing(t.id))
tr.addEventListener("click", () => this.selectTemplate(t))
tr.addEventListener("keydown", (event) => {
  if (event.target !== tr || !["Enter", " "].includes(event.key)) return
  event.preventDefault()
  this.selectTemplate(t)
})
```

Use these row actions:

```javascript
actions.appendChild(this.button("Send", () => this.openSend(t)))
actions.appendChild(this.button("Edit", () => this.selectTemplate(t)))
actions.appendChild(this.button("Delete", () => this.destroy(t), "text-rose-600"))
```

Replace the event listener inside `button()` with:

```javascript
b.addEventListener("click", (event) => {
  event.stopPropagation()
  onClick(event)
})
```

- [ ] **Step 6: Add guarded population and blank-reset methods**

Replace `newTemplate()`, `openEditor(t)`, and `closeEditor()` with:

```javascript
newTemplate() { this._resetEditor() }

openEditor(template) { this.selectTemplate(template) }

selectTemplate(template) {
  if (this.editorSession.isEditing(template.id)) return
  if (!this._confirmEditorReplacement()) return
  this._populateEditor(template)
}

_confirmEditorReplacement() {
  return this.editorSession.mayReplace(() => window.confirm("Discard unsaved template changes?"))
}

_populateEditor(template) {
  this._syncGuard(() => {
    this.fNameTarget.value = template.name || ""
    this.fKindTarget.value = template.kind || "cmdscript"
    this.fOutputTarget.value = template.output || ""
    this.fTagsTarget.value = (template.tags || []).join(", ")
    this.fDescriptionTarget.value = template.description || ""
    this.commandsTarget.replaceChildren()
    ;(template.commands || []).forEach((command) => this.addCommand(command))
    if (!(template.commands || []).length) this.addCommand()
    this._setTarget(template.target)
    this._setYamlValue(template.yaml || "")
  })
  this.errorsTarget.classList.add("hidden")
  if (this.sendDialogTarget.open) this.sendDialogTarget.close()
  this.lastEdited = "structured"
  this.editorSession.markClean(template.id)
  this.applyStoredMode()
  this.render()
  this.fNameTarget.focus()
}

_resetEditor({ guard = true, focus = true } = {}) {
  if (guard && !this._confirmEditorReplacement()) return false
  this._syncGuard(() => {
    this.fNameTarget.value = ""
    this.fKindTarget.value = "cmdscript"
    this.fOutputTarget.value = ""
    this.fTagsTarget.value = ""
    this.fDescriptionTarget.value = ""
    this.commandsTarget.replaceChildren()
    this.addCommand()
    this._setTarget(null)
    this._setYamlValue("")
  })
  this.errorsTarget.classList.add("hidden")
  this.lastEdited = "structured"
  this.editorSession.markClean(null)
  this.applyStoredMode()
  this.render()
  if (focus) this.fNameTarget.focus()
  return true
}

closeEditor() { this._resetEditor() }
```

- [ ] **Step 7: Adapt Send to the native modal without changing selection**

At the end of `openSend(t)`, replace visibility changes with:

```javascript
if (!this.sendDialogTarget.open) this.sendDialogTarget.showModal()
```

Remove `this.editorTarget.classList.add("hidden")`. Replace `closeSend()` with:

```javascript
closeSend() { this.sendDialogTarget.close() }
```

- [ ] **Step 8: Run pure tests and syntax checks**

Run:

```bash
node --test test/javascript/template_search_test.mjs test/javascript/template_editor_session_test.mjs test/javascript/template_batch_importer_test.mjs
node --check app/javascript/controllers/control_center_templates_controller.js
node --check app/javascript/lib/template_search.js
node --check app/javascript/lib/template_editor_session.js
```

Expected: 20 tests pass, 0 fail; all syntax checks exit 0.

- [ ] **Step 9: Review checkpoint without committing**

Run:

```bash
git diff --check
git diff -- web/app/javascript/controllers/control_center_templates_controller.js
```

Expected: batch import methods remain intact; refresh preserves the last good list; row buttons stop propagation; editor hide/show calls are absent.

---

### Task 5: Dirty-state wiring, save transitions, and selected deletion

**Files:**
- Modify: `web/app/javascript/controllers/control_center_templates_controller.js`
- Modify: `web/test/integration/control_center/template_workspace_test.rb`

**Interfaces:**
- Consumes: `TemplateEditorSession` initialized in Task 4.
- Produces: every user-authored structured or YAML change marks the session dirty; programmatic loads and structured/YAML synchronization remain clean.

- [ ] **Step 1: Recheck controller and view diffs**

Run:

```bash
git status --short
git diff -- web/app/javascript/controllers/control_center_templates_controller.js web/app/views/control_center/templates/index.html.erb
```

Expected: only approved Templates-page work overlaps these files.

- [ ] **Step 2: Wire bubbling structured-form and CodeMirror changes**

Add this controller action near the editor methods:

```javascript
markEditorDirty() {
  if (!this._syncing) this.editorSession.markDirty()
}
```

Inside the existing CodeMirror `updateListener`, replace its user-change branch with:

```javascript
if (u.docChanged && !this._syncing) {
  this.editorSession.markDirty()
  this.lastEdited = "yaml"
  this.validateYaml()
}
```

Expected: bubbling native input/change events cover all structured fields, while
`_syncGuard` keeps programmatic population clean.

- [ ] **Step 3: Mark non-input editor actions dirty**

Replace the opening of `addCommand(command = null)` with:

```javascript
addCommand(commandOrEvent = null) {
  const fromUser = typeof Event !== "undefined" && commandOrEvent instanceof Event
  const command = fromUser ? null : commandOrEvent
  if (fromUser && !this._syncing) this.editorSession.markDirty()
  const row = this.commandRowTarget.content.firstElementChild.cloneNode(true)
```

Keep the current `if (command) { ... }` field population and append statements
after that opening. Replace `removeCommand(event)` with:

```javascript
removeCommand(event) {
  event.target.closest("[data-row]").remove()
  this.editorSession.markDirty()
  this.validate()
}
```

In the `FileReader.onload` body of `onFile`, add this immediately before `showYaml()`:

```javascript
this.editorSession.markDirty()
```

- [ ] **Step 4: Make save use session identity and establish clean state**

In `_save`, replace URL and method selection with:

```javascript
const editingId = this.editorSession.editingId
const url = editingId ? `${this.indexUrlValue}/${editingId}` : this.indexUrlValue
const method = editingId ? "PATCH" : "POST"
```

Replace the successful response branch with:

```javascript
if (ok) {
  const savedId = data?.id ?? editingId
  this.editorSession.markClean(savedId)
  await this.refresh()
  if (close) this._resetEditor({ guard: false })
  else {
    this.render()
    this._flashSaved()
  }
} else if (source === "yaml") {
```

Keep the existing YAML and structured failure bodies after the shown `else if`.
Do not mark clean on failure. Remove all remaining references to `this.editingId`.

- [ ] **Step 5: Preserve or reset the editor correctly after deletion**

Replace `destroy(t)` with:

```javascript
async destroy(template) {
  if (!window.confirm(`Delete template "${template.name}"?`)) return
  const { ok } = await apiFetch(`${this.indexUrlValue}/${template.id}`, { method: "DELETE" })
  if (!ok) return

  const deletedSelection = this.editorSession.isEditing(template.id)
  await this.refresh()
  if (deletedSelection) this._resetEditor({ guard: false })
}
```

Expected: deleting another row preserves the current editor; deleting the
selected row resets it only after the API confirms deletion.

- [ ] **Step 6: Add permanent-editor action coverage**

Append this test to `template_workspace_test.rb`:

```ruby
test "keeps permanent-editor actions available" do
  assert_select "button[data-action='control-center-templates#newTemplate']", text: /New template/
  assert_select "button[data-action='control-center-templates#save']", text: /^\s*Save\s*$/
  assert_select "button[data-action='control-center-templates#saveAndClose']", text: /Save & close/
  assert_select "button[data-action='control-center-templates#closeEditor']", text: /Cancel/
end
```

- [ ] **Step 7: Run focused automated checks**

Run:

```bash
node --test test/javascript/template_search_test.mjs test/javascript/template_editor_session_test.mjs test/javascript/template_batch_importer_test.mjs
node --check app/javascript/controllers/control_center_templates_controller.js
DB_HOST=localhost DB_PORT=5433 DB_DATABASE_TEST=hunter_test RAILS_ENV=test /opt/rbenv/shims/bundle exec rails test test/integration/control_center/template_workspace_test.rb test/integration/control_center/template_import_test.rb
```

Expected: 20 Node tests and 7 Rails integration tests pass with 0 failures.

- [ ] **Step 8: Review checkpoint without committing**

Run:

```bash
rg -n "editingId|editorTarget\.classList|markEditorDirty|editorSession" app/javascript/controllers/control_center_templates_controller.js
git diff --check
```

Expected: no `this.editingId`; no editor hide/show calls; dirty state is set by
native form events, CodeMirror, command add/remove, and file upload.

---

### Task 6: Regression verification and browser acceptance

**Files:**
- Verify all files from Tasks 1–5.
- Modify `docs/superpowers/specs/2026-07-23-control-center-template-workspace-design.md` only if every required check passes.

**Interfaces:**
- No new production interface; this task verifies the complete workspace contract.

- [ ] **Step 1: Recheck concurrent-work boundaries**

Run from the repository root:

```bash
git status --short
git diff --name-only
git diff -- web/config/routes.rb web/app/controllers/control_center/base_controller.rb web/test/integration/control_center/tabs_test.rb
```

Expected: no diff in routes, the Control Center tab registry, or shared tab test;
all contributor-owned Ansible changes remain untouched.

- [ ] **Step 2: Run every JavaScript test and syntax check**

Run from `web/`:

```bash
node --test test/javascript/*.mjs
node --check app/javascript/controllers/control_center_templates_controller.js
node --check app/javascript/lib/template_search.js
node --check app/javascript/lib/template_editor_session.js
node --check app/javascript/lib/template_batch_importer.js
```

Expected: all tests pass, 0 fail; all syntax checks exit 0.

- [ ] **Step 3: Run focused Rails and Control Center tests**

Run:

```bash
DB_HOST=localhost DB_PORT=5433 DB_DATABASE_TEST=hunter_test RAILS_ENV=test /opt/rbenv/shims/bundle exec rails test \
  test/helpers/icon_helper_test.rb \
  test/integration/control_center/template_workspace_test.rb \
  test/integration/control_center/template_import_test.rb \
  test/integration/control_center/tabs_test.rb \
  test/services/control_center \
  test/models/control_center \
  test/integration/api/v1/control_center
```

Expected: all focused tests pass with 0 failures and 0 errors. If PostgreSQL is
unreachable, report the exact connection error and do not claim Rails coverage.

- [ ] **Step 4: Run static rendering, lint, and asset checks**

Run:

```bash
/opt/rbenv/shims/bundle exec rubocop \
  test/integration/control_center/template_workspace_test.rb \
  test/integration/control_center/template_import_test.rb \
  test/helpers/icon_helper_test.rb
/opt/rbenv/shims/erb -x -T - app/views/control_center/templates/index.html.erb | /opt/rbenv/shims/ruby -c
RAILS_ENV=test SECRET_KEY_BASE_DUMMY=1 /opt/rbenv/shims/bundle exec rails assets:precompile
git diff --check
```

Expected: RuboCop reports no offenses; ERB reports `Syntax OK`; Tailwind/assets
finish successfully; diff check is silent.

- [ ] **Step 5: Run the full Rails suite**

Run:

```bash
DB_HOST=localhost DB_PORT=5433 DB_DATABASE_TEST=hunter_test RAILS_ENV=test /opt/rbenv/shims/bundle exec rails test
```

Expected: full suite passes with 0 failures and 0 errors. A database connection
failure is an environment blocker, not a pass.

- [ ] **Step 6: Perform desktop browser acceptance**

Open the authenticated Templates tab and verify:

1. Editor is visible above the library with blank fields and one command row.
2. Editor and table scroll independently; search toolbar and table header remain visible.
3. Plain text, every dork key, AND, OR, parentheses, quotes, and wildcards update the count and results correctly.
4. Clear, syntax help, ordinary empty state, and no-match state are distinct and correct.
5. Mouse row click and Enter/Space activation load and highlight the intended template.
6. Send, Edit, and Delete do not accidentally trigger row activation.
7. Declining a dirty row switch preserves editor and selection; accepting loads the new row.
8. The same prompt behavior works after CodeMirror YAML edits.
9. Save keeps selection; Save & close, accepted Cancel, and accepted New template reset blank.
10. Filtering out the selected row, Refresh, and completed import preserve editor contents and reapply the query.
11. Send opens modally without hiding or clearing the editor beneath it.
12. All checks work in light and dark themes.

Expected: every interaction matches the approved design.

- [ ] **Step 7: Perform mobile responsive acceptance**

At a narrow viewport, verify the editor and library use ordinary vertical flow,
controls wrap without overlap, the table remains horizontally usable, and no
desktop height constraint traps scrolling.

Expected: editor remains above the library and all actions remain reachable.

- [ ] **Step 8: Mark the design implemented only after complete verification**

If and only if Steps 2–7 all pass, change the design header to:

```markdown
**Status:** Implemented
```

If any Rails or browser check is blocked, leave `**Status:** Approved` and report
the unverified items explicitly.

- [ ] **Step 9: Final review checkpoint without committing**

Run:

```bash
git status --short
git diff --stat
git diff --check
```

Expected: only approved Templates workspace/search files plus previously known
bulk-import/icon work and contributor-owned files are present. Do not stage or
commit unless the user explicitly requests it.
