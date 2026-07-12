# Control Center Editor: Save Modes + Live Split View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a keep-open "Save" (alongside "Save & close") and a live-syncing Structured|YAML|Split editor to the Control Center template editor.

**Architecture:** The editor is one Stimulus controller (`control_center_templates_controller.js`) driving an ERB panel. Live structured↔YAML conversion is done server-side via the existing dry-run endpoints (`validate`, `validate_yaml`) — no DB writes, no duplicated parse/render logic in JS. Persistence happens only on Save / Save & close. The `validate` action is enriched to also return rendered YAML; everything else is view + controller JS.

**Tech Stack:** Ruby 3.3.6, Rails 8, Hotwire (Stimulus/Turbo), Tailwind CSS v4, Minitest. Ruby namespace `Hunter`; module code under `ControlCenter`.

## Global Constraints

- Rails app lives in `web/`; run all `bin/rails` commands from `web/`.
- Tests need a reachable Postgres `hunter_test`; Mongo is doubled (not needed here).
- The editor builds all list/rows via `createElement`/`textContent` — never `innerHTML` — so template-supplied strings can't inject HTML. Preserve this.
- Live-sync endpoints (`validate`, `validate_yaml`) are dry-run and MUST NOT persist.
- Commit author `Claude <noreply@anthropic.com>`; commit messages are a single sentence, no body. **Only commit when these steps say to** (the repo convention is "commit when asked"; this plan is that instruction).
- localStorage key for the persisted editor mode: `hunter.cc.editorMode` (values `structured` | `yaml` | `split`).

---

## File Structure

- `web/app/controllers/api/v1/control_center/templates_controller.rb` — enrich `validate` to render + return `yaml`; drop the now-unused `commands_param` helper.
- `web/test/integration/api/v1/control_center/templates_test.rb` — cover `validate` returning `yaml`.
- `web/app/views/control_center/templates/index.html.erb` — three-way mode toggle, split layout wrapper, two save buttons + a "Saved" flash.
- `web/app/javascript/controllers/control_center_templates_controller.js` — split mode, localStorage persistence, `_save({ close })` with `editingId` capture, live bidirectional sync + `lastEdited`.

---

## Task 1: `validate` returns rendered YAML

**Files:**
- Modify: `web/app/controllers/api/v1/control_center/templates_controller.rb:44-47` (the `validate` action) and remove `commands_param` at `:76-78`.
- Test: `web/test/integration/api/v1/control_center/templates_test.rb`

**Interfaces:**
- Produces: `POST /api/v1/control_center/templates/validate` now responds `{ valid: Boolean, errors: [String], yaml: String }`. `yaml` is the cmdscript render of the posted structured params (best-effort over partial input). Still dry-run — no persistence.

- [ ] **Step 1: Write the failing test**

Add to `web/test/integration/api/v1/control_center/templates_test.rb` (before the final `end`):

```ruby
  test "validate returns rendered yaml for structured params without persisting" do
    sign_in_as(@user)
    post "/api/v1/control_center/templates/validate",
         params: { name: "probe", kind: "cmdscript",
                   commands: [{ command: "httpx", args: ["-u", "x", "-silent"], operator: "" }] },
         as: :json
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal true, body["valid"]
    assert_includes body["yaml"], "command: httpx"
    assert_includes body["yaml"], "['-u', 'x']"
    assert_equal 0, ControlCenter::Template.count
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bin/rails test test/integration/api/v1/control_center/templates_test.rb -n "/validate returns rendered yaml/"`
Expected: FAIL — `body["yaml"]` is `nil`, so `assert_includes nil, "command: httpx"` raises.

- [ ] **Step 3: Write the implementation**

In `web/app/controllers/api/v1/control_center/templates_controller.rb`, replace the `validate` action (lines 44-47):

```ruby
        def validate
          attrs = template_params
          errors = ::ControlCenter::TemplateValidator.call(attrs["commands"])
          yaml = ::ControlCenter::TemplateRenderer.to_yaml(::ControlCenter::Template.new(attrs))
          render json: { valid: errors.empty?, errors: errors, yaml: yaml }
        end
```

Then delete the now-unused `commands_param` helper (lines 76-78):

```ruby
        def commands_param
          params.permit(commands: [:command, :operator, { args: [] }]).to_h["commands"]
        end
```

(`template_params` already permits `name, kind, description, output, tags, commands, target` and returns a string-keyed Hash, which `Template.new` and `TemplateValidator.call(attrs["commands"])` both accept. `Template.new` here is never saved.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd web && bin/rails test test/integration/api/v1/control_center/templates_test.rb`
Expected: PASS (all tests in the file, including the existing "validate endpoint reports errors without persisting").

- [ ] **Step 5: Commit**

```bash
git add web/app/controllers/api/v1/control_center/templates_controller.rb web/test/integration/api/v1/control_center/templates_test.rb
git commit -m "Return rendered cmdscript YAML from the Control Center validate endpoint"
```

---

## Task 2: Save and Save & close buttons

No JS unit harness exists in this repo, so this task is verified manually in the running app.

**Files:**
- Modify: `web/app/views/control_center/templates/index.html.erb:149-156` (the save/cancel button row).
- Modify: `web/app/javascript/controllers/control_center_templates_controller.js` — targets list (`:9-14`), `save()` (`:266-291`).

**Interfaces:**
- Consumes: `apiFetch` create/update responses include `id` (see `serialize` in the controller).
- Produces: controller methods `save()` (keep open) and `saveAndClose()` (close), both delegating to `_save({ close })`. `_flashSaved()` shows a transient indicator. After a create, `this.editingId` is set from the response so the next save is a PATCH.

- [ ] **Step 1: Replace the button row in the view**

In `web/app/views/control_center/templates/index.html.erb`, replace lines 149-156:

```erb
    <div class="mt-4 flex items-center gap-2">
      <button type="button" data-control-center-templates-target="save" data-action="control-center-templates#save"
              class="inline-flex items-center gap-1.5 rounded-md bg-zinc-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-zinc-700 disabled:opacity-40 dark:bg-white dark:text-zinc-900 dark:hover:bg-zinc-200">
        <%= heroicon "check", classes: "h-4 w-4" %> Save
      </button>
      <button type="button" data-control-center-templates-target="saveClose" data-action="control-center-templates#saveAndClose"
              class="inline-flex items-center gap-1.5 rounded-md bg-zinc-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-zinc-700 disabled:opacity-40 dark:bg-white dark:text-zinc-900 dark:hover:bg-zinc-200">
        <%= heroicon "check", classes: "h-4 w-4" %> Save &amp; close
      </button>
      <button type="button" data-action="control-center-templates#closeEditor"
              class="rounded-md border border-zinc-300 px-3 py-1.5 text-sm font-medium text-zinc-700 hover:bg-zinc-100 dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800">Cancel</button>
      <span data-control-center-templates-target="savedFlash"
            class="hidden rounded bg-emerald-100 px-1.5 py-0.5 text-xs font-medium text-emerald-800 dark:bg-emerald-950/50 dark:text-emerald-300">Saved</span>
    </div>
```

- [ ] **Step 2: Add the new targets**

In `web/app/javascript/controllers/control_center_templates_controller.js`, in the `static targets` array (lines 9-14), add `"saveClose"` and `"savedFlash"`. The `save` target already exists. Result:

```js
  static targets = [
    "rows", "empty", "editor", "commands", "commandRow", "errors", "save", "saveClose", "savedFlash",
    "fName", "fKind", "fOutput", "fTags", "fDescription",
    "sendDialog", "sendName", "sendTargets", "sendQueue", "sendChunk", "sendDelay", "sendResult",
    "modeStructured", "modeYaml", "structuredPanel", "yamlPanel", "yamlText", "yamlErrors", "yamlValid", "fileInput",
  ]
```

- [ ] **Step 3: Replace `save()` with the two-button implementation**

In the same file, replace the entire `async save() { ... }` method (lines 266-291) with:

```js
  save() { this._save({ close: false }) }
  saveAndClose() { this._save({ close: true }) }

  async _save({ close }) {
    let body
    const source = this.mode === "yaml" ? "yaml" : "structured"
    if (source === "yaml") {
      body = { yaml: this.yamlTextTarget.value }
    } else {
      body = {
        name: this.fNameTarget.value.trim(),
        kind: this.fKindTarget.value,
        output: this.fOutputTarget.value.trim(),
        description: this.fDescriptionTarget.value,
        tags: this.fTagsTarget.value.split(",").map((s) => s.trim()).filter(Boolean),
        commands: this.collectCommands(),
      }
    }
    const url = this.editingId ? `${this.indexUrlValue}/${this.editingId}` : this.indexUrlValue
    const method = this.editingId ? "PATCH" : "POST"
    const { ok, data } = await apiFetch(url, { method, body })
    if (ok) {
      if (data && data.id) this.editingId = data.id
      this.refresh()
      if (close) this.closeEditor()
      else this._flashSaved()
    } else if (source === "yaml") {
      this._renderYamlErrors((data && data.detail) || ["save failed"])
    } else {
      this.showErrors((data && data.detail) || ["save failed"])
    }
  }

  _flashSaved() {
    this.savedFlashTarget.classList.remove("hidden")
    clearTimeout(this._flashTimer)
    this._flashTimer = setTimeout(() => this.savedFlashTarget.classList.add("hidden"), 1500)
  }
```

- [ ] **Step 4: Clear the flash timer on disconnect**

In `disconnect()` (lines 23-26), add the flash timer to the cleanup:

```js
  disconnect() {
    clearTimeout(this._valTimer)
    clearTimeout(this._yamlTimer)
    clearTimeout(this._flashTimer)
  }
```

- [ ] **Step 5: Manually verify in the app**

Run the app (docker-compose up, or the project `/run` skill), open Control Center → New template. Fill Name + a command, click **Save**: the list refreshes, the editor stays open, and a green "Saved" appears briefly. Click **Save** again: no duplicate row appears (it PATCHed). Click **Save & close**: the editor closes. Confirm the row count is correct in the list.

- [ ] **Step 6: Commit**

```bash
git add web/app/views/control_center/templates/index.html.erb web/app/javascript/controllers/control_center_templates_controller.js
git commit -m "Add keep-open Save alongside Save & close in the Control Center editor"
```

---

## Task 3: Split mode + layout + persisted preference

Verified manually (no JS unit harness).

**Files:**
- Modify: `web/app/views/control_center/templates/index.html.erb` — mode toggle group (`:53-65`) and wrap the two panels (`:67-147`).
- Modify: `web/app/javascript/controllers/control_center_templates_controller.js` — targets (`:9-14`), `connect()` (`:16-21`), `newTemplate()` (`:77-92`), `openEditor()` (`:94-109`), `showStructured`/`showYaml`/`_activate` (`:115-134`).

**Interfaces:**
- Produces: `this.mode` ∈ `{"structured","yaml","split"}`; methods `showStructured()`, `showYaml()`, `showSplit()`, `_applyMode()`, `applyStoredMode()`. Mode is persisted to localStorage `hunter.cc.editorMode` and restored when the editor opens.

- [ ] **Step 1: Add the Split toggle button**

In `web/app/views/control_center/templates/index.html.erb`, replace the toggle group (lines 54-59) — the `<div class="inline-flex ...">` block — with:

```erb
      <div class="inline-flex overflow-hidden rounded-md border border-zinc-300 dark:border-zinc-700">
        <button type="button" data-control-center-templates-target="modeStructured" data-action="control-center-templates#showStructured"
                class="px-3 py-1 text-sm font-medium bg-zinc-900 text-white dark:bg-white dark:text-zinc-900">Structured</button>
        <button type="button" data-control-center-templates-target="modeYaml" data-action="control-center-templates#showYaml"
                class="px-3 py-1 text-sm font-medium text-zinc-700 hover:bg-zinc-100 dark:text-zinc-200 dark:hover:bg-zinc-800">YAML</button>
        <button type="button" data-control-center-templates-target="modeSplit" data-action="control-center-templates#showSplit"
                class="px-3 py-1 text-sm font-medium text-zinc-700 hover:bg-zinc-100 dark:text-zinc-200 dark:hover:bg-zinc-800">Split</button>
      </div>
```

- [ ] **Step 2: Wrap the two panels in a grid**

In the same view, wrap the existing `structuredPanel` div (opens at line 67) and `yamlPanel` div (closes at line 147) in a split wrapper. Immediately **before** line 67 (`<div data-control-center-templates-target="structuredPanel">`) insert:

```erb
    <div data-control-center-templates-target="splitWrap" class="grid gap-4">
```

and immediately **after** the `yamlPanel` closing `</div>` (line 147) add one more closing tag:

```erb
    </div>
```

(The two panels are now children of `splitWrap`. In split mode `lg:grid-cols-2` is toggled on; otherwise it's a single-column grid with one child shown.)

- [ ] **Step 3: Register the `modeSplit` and `splitWrap` targets**

In the controller `static targets` array, add `"modeSplit"` and `"splitWrap"` to the mode-related line:

```js
    "modeStructured", "modeYaml", "modeSplit", "splitWrap", "structuredPanel", "yamlPanel", "yamlText", "yamlErrors", "yamlValid", "fileInput",
```

- [ ] **Step 4: Replace the mode methods**

Replace `showStructured()`, `showYaml()`, and `_activate()` (lines 115-134) with:

```js
  showStructured() { this.mode = "structured"; this._applyMode(); this.validate() }
  showYaml() { this.mode = "yaml"; this._applyMode(); this.validateYaml() }
  showSplit() { this.mode = "split"; this._applyMode(); this.validate(); this.validateYaml() }

  applyStoredMode() {
    const stored = localStorage.getItem("hunter.cc.editorMode")
    this.mode = ["structured", "yaml", "split"].includes(stored) ? stored : "structured"
    this._applyMode()
    this.validate()
    if (this.mode !== "structured") this.validateYaml()
  }

  _applyMode() {
    const showStruct = this.mode === "structured" || this.mode === "split"
    const showYaml = this.mode === "yaml" || this.mode === "split"
    this.structuredPanelTarget.classList.toggle("hidden", !showStruct)
    this.yamlPanelTarget.classList.toggle("hidden", !showYaml)
    this.splitWrapTarget.classList.toggle("lg:grid-cols-2", this.mode === "split")
    const btns = { structured: this.modeStructuredTarget, yaml: this.modeYamlTarget, split: this.modeSplitTarget }
    Object.entries(btns).forEach(([m, btn]) => {
      const on = m === this.mode
      btn.classList.toggle("bg-zinc-900", on)
      btn.classList.toggle("text-white", on)
      btn.classList.toggle("dark:bg-white", on)
      btn.classList.toggle("dark:text-zinc-900", on)
    })
    localStorage.setItem("hunter.cc.editorMode", this.mode)
  }
```

- [ ] **Step 5: Restore the stored mode when the editor opens**

In `newTemplate()` (line 91) and `openEditor()` (line 108), replace the trailing `this.showStructured()` call with `this.applyStoredMode()`. Both methods currently end with `this.showStructured()`; change each to:

```js
    this.applyStoredMode()
```

(Leave `onFile()`'s `this.showYaml()` as-is — uploading a file should switch to YAML.)

- [ ] **Step 6: Manually verify**

Reload the app, open the editor, click **Split** — both panels appear side by side (stacked on a narrow window). Reload the page and open the editor again: it opens in Split without re-clicking. Switch to Structured, reload, reopen: it opens Structured. Resize the window narrow: the two panels stack.

- [ ] **Step 7: Commit**

```bash
git add web/app/views/control_center/templates/index.html.erb web/app/javascript/controllers/control_center_templates_controller.js
git commit -m "Add a persisted Split view to the Control Center template editor"
```

---

## Task 4: Live bidirectional sync

Verified manually (no JS unit harness).

**Files:**
- Modify: `web/app/javascript/controllers/control_center_templates_controller.js` — `connect()` (`:16-21`), input handlers `validate()`/`_doValidateYaml()`, add `lastEdited` tracking + population helpers, and refine `_save` source selection.

**Interfaces:**
- Consumes: `validate` response `{ valid, errors, yaml }` (Task 1); `validate_yaml` response `{ valid, errors, template }` (existing).
- Produces: `this.lastEdited` ∈ `{"structured","yaml"}`; helpers `_populateStructured(attrs)`, `_syncGuard(fn)`. Editing either side mirrors into the other while in Split; `_save` sends the `lastEdited` representation.

- [ ] **Step 1: Initialize sync state in `connect()`**

Replace `connect()` (lines 16-21) with:

```js
  connect() {
    this.editingId = null
    this.sendTemplate = null
    this.mode = "structured"
    this.lastEdited = "structured"
    this._syncing = false
    this.refresh()
  }
```

- [ ] **Step 2: Track the edited side + mirror structured → YAML**

Replace `validate()` (lines 245-254) with a version that records `lastEdited` and, when the YAML pane is visible (yaml or split), writes the freshly rendered YAML into the textarea. Setting `.value` does not dispatch `input`, so this does not re-trigger the YAML handler:

```js
  async validate() {
    if (!this._syncing) this.lastEdited = "structured"
    const { ok, data } = await apiFetch(this.validateUrlValue, {
      method: "POST",
      body: {
        name: this.fNameTarget.value.trim(),
        kind: this.fKindTarget.value,
        output: this.fOutputTarget.value.trim(),
        description: this.fDescriptionTarget.value,
        tags: this.fTagsTarget.value.split(",").map((s) => s.trim()).filter(Boolean),
        commands: this.collectCommands(),
      },
    })
    const errors = ok && data ? data.errors : ["validation request failed"]
    const valid = ok && data && data.valid && this.fNameTarget.value.trim().length > 0
    this.showErrors(valid ? [] : errors)
    this.saveTarget.disabled = !valid
    this.saveCloseTarget.disabled = !valid
    if (this.mode !== "structured" && ok && data && typeof data.yaml === "string" && !this._syncing) {
      this.yamlTextTarget.value = data.yaml
    }
  }
```

- [ ] **Step 3: Mirror YAML → structured**

Replace `_doValidateYaml()` (lines 152-159) with a version that records `lastEdited` and, when structured is visible (structured is only visible in split alongside yaml here), repopulates the form from the parsed attrs:

```js
  async _doValidateYaml() {
    if (!this._syncing) this.lastEdited = "yaml"
    const { ok, data } = await apiFetch(this.validateYamlUrlValue, { method: "POST", body: { yaml: this.yamlTextTarget.value } })
    const valid = ok && data && data.valid
    const errors = ok && data ? data.errors : ["validation request failed"]
    this.yamlValidTarget.classList.toggle("hidden", !valid)
    this._renderYamlErrors(valid ? [] : errors)
    this.saveTarget.disabled = !valid
    this.saveCloseTarget.disabled = !valid
    if (this.mode === "split" && ok && data && data.template && !this._syncing) {
      this._populateStructured(data.template)
    }
  }
```

- [ ] **Step 4: Add the structured-population helper + sync guard**

Add these methods (place them just after `_doValidateYaml`):

```js
  // Fill the structured form from parsed YAML attrs (from validate_yaml). Wrapped
  // in _syncGuard so the resulting input-driven validate() does not echo back into
  // the YAML pane the user is typing in.
  _populateStructured(attrs) {
    this._syncGuard(() => {
      this.fNameTarget.value = attrs.name || ""
      this.fKindTarget.value = attrs.kind || "cmdscript"
      this.fOutputTarget.value = attrs.output || ""
      this.fTagsTarget.value = (attrs.tags || []).join(", ")
      this.fDescriptionTarget.value = attrs.description || ""
      this.commandsTarget.replaceChildren()
      ;(attrs.commands || []).forEach((c) => this.addCommand(c))
      if (!(attrs.commands || []).length) this.addCommand()
    })
  }

  _syncGuard(fn) {
    this._syncing = true
    try { fn() } finally { this._syncing = false }
  }
```

- [ ] **Step 5: Send the last-edited representation on save**

In `_save({ close })` (added in Task 2), replace the source line:

```js
    const source = this.mode === "yaml" ? "yaml" : "structured"
```

with:

```js
    const source = this.lastEdited === "yaml" ? "yaml" : "structured"
```

- [ ] **Step 6: Reset `lastEdited` when opening the editor**

In `newTemplate()` and `openEditor()`, set `this.lastEdited = "structured"` just before the `this.applyStoredMode()` call added in Task 3. In `onFile()`'s reader `onload`, set `this.lastEdited = "yaml"` before `this.showYaml()` (uploaded YAML is the source of truth). Concretely, `onFile`'s `reader.onload` becomes:

```js
    reader.onload = () => {
      this.yamlTextTarget.value = String(reader.result || "")
      this.lastEdited = "yaml"
      this.showYaml()
    }
```

- [ ] **Step 7: Manually verify the live mirror**

Reload, open the editor, click **Split**. Type in a structured Name/command → the YAML pane updates (~300ms later) with the rendered YAML, args grouped and single-quoted. Edit the YAML pane (e.g. change the command name) → the structured form updates to match. Confirm no flicker/loop (typing on one side never fights the other). Type invalid YAML → the structured form is left intact (not wiped). Then **Save** after editing only YAML and reload the list to confirm the YAML representation was persisted; repeat editing only structured.

- [ ] **Step 8: Commit**

```bash
git add web/app/javascript/controllers/control_center_templates_controller.js
git commit -m "Live-sync structured and YAML panes in the Control Center split editor"
```

---

## Task 5: YAML code editor (CodeMirror 6)

> **Supersedes** the earlier highlight.js-overlay approach. The pane is a real
> editable editor (line numbers, theming) instead of a read-only highlighter
> behind a textarea. Execute **after Task 3 and before Task 4** so the sync code
> reads/writes the editor value. Verified manually + headless bundle checks.

**Files:**
- Create: `web/vendor/javascript/codemirror.min.js` — self-contained CM6 ESM
  bundle (done).
- Modify: `web/config/importmap.rb` — `pin "codemirror", to: "codemirror.min.js"`
  (done); remove the unused `highlight.js/yaml` pin (done).
- Delete: `web/vendor/javascript/highlight/yaml.min.js` (done — no longer used).
- Modify: `web/app/views/control_center/templates/index.html.erb` — replace the
  YAML overlay with a `yamlEditor` mount `<div>`.
- Modify: `web/app/javascript/controllers/control_center_templates_controller.js` —
  mount an `EditorView`, theme compartment + `MutationObserver`, `_yamlValue()` /
  `_setYamlValue()`, update listener; drop hljs imports and the overlay helpers.

**Interfaces:**
- Produces: `_yamlValue()` (reads the editor doc) and `_setYamlValue(str)` (replaces
  it inside the `_syncing` guard). Task 4's YAML reads/writes go through these.

- [ ] **Step 1: Build + vendor the bundle (supply-chain safe)**

Install the official packages at pinned versions from the npm registry and bundle
locally with esbuild into one committed file (no runtime CDN):

```bash
npm install --no-audit --no-fund \
  codemirror@6.0.2 @codemirror/state@6.7.1 @codemirror/view@6.43.6 \
  @codemirror/commands@6.10.4 @codemirror/language@6.12.4 \
  @codemirror/lang-yaml@6.1.3 @codemirror/theme-one-dark@6.1.3 esbuild@0.25.5
# entry.js re-exports: EditorView, keymap, placeholder from @codemirror/view;
# EditorState, Compartment from @codemirror/state; basicSetup from codemirror;
# yaml from @codemirror/lang-yaml; oneDark from @codemirror/theme-one-dark;
# indentWithTab from @codemirror/commands.
npx esbuild entry.js --bundle --format=esm --minify --banner:js='/*! CodeMirror 6 (MIT) vendored bundle — versions in spec */' \
  --outfile=web/vendor/javascript/codemirror.min.js
```

- [ ] **Step 2: Mount container in the view**

Replace the YAML overlay markup in `yamlPanel` with:

```erb
      <div data-control-center-templates-target="yamlEditor"
           class="overflow-hidden rounded-md border border-zinc-300 dark:border-zinc-700"></div>
```

- [ ] **Step 3: Imports + targets**

```js
import {
  EditorView, EditorState, basicSetup, yaml, oneDark,
  keymap, indentWithTab, placeholder, Compartment,
} from "codemirror"
```

Targets: drop `yamlText`, `yamlHighlight`; add `yamlEditor`.

- [ ] **Step 4: Mount, theme, value helpers**

In `connect()` call `this._mountEditor()`; in `disconnect()` add
`this._themeObserver?.disconnect(); this.editorView?.destroy()`. Add:

```js
  _mountEditor() {
    this._themeCompartment = new Compartment()
    this.editorView = new EditorView({
      parent: this.yamlEditorTarget,
      state: EditorState.create({ doc: "", extensions: [
        basicSetup, yaml(), keymap.of([indentWithTab]),
        placeholder("name: 'nuclei-cve'\ncommands:\n  - command: 'nuclei'"),
        this._themeCompartment.of(this._darkMode() ? oneDark : []),
        EditorView.theme({ "&": { fontSize: "0.8125rem" }, ".cm-scroller": { minHeight: "16rem", maxHeight: "26rem", overflow: "auto" } }),
        EditorView.updateListener.of((u) => { if (u.docChanged && !this._syncing) { this.lastEdited = "yaml"; this.validateYaml() } }),
      ] }),
    })
    this._themeObserver = new MutationObserver(() =>
      this.editorView.dispatch({ effects: this._themeCompartment.reconfigure(this._darkMode() ? oneDark : []) }))
    this._themeObserver.observe(document.documentElement, { attributes: true, attributeFilter: ["class"] })
  }
  _darkMode() { return document.documentElement.classList.contains("dark") }
  _yamlValue() { return this.editorView ? this.editorView.state.doc.toString() : "" }
  _setYamlValue(str) {
    if (!this.editorView) return
    const prev = this._syncing; this._syncing = true
    this.editorView.dispatch({ changes: { from: 0, to: this.editorView.state.doc.length, insert: str || "" } })
    this._syncing = prev
  }
```

- [ ] **Step 5: Route all YAML reads/writes through the helpers**

`newTemplate`/`openEditor` → `this._setYamlValue("")` / `this._setYamlValue(t.yaml || "")`;
`onFile` → `this._setYamlValue(...)`; `_doValidateYaml` & `_save` read `this._yamlValue()`;
`validate` structured→YAML → `this._setYamlValue(data.yaml)`; `_applyMode` calls
`this.editorView?.requestMeasure()` when the YAML pane becomes visible; delete
`_refreshYamlHighlight`/`syncYamlScroll` and the hljs imports.

- [ ] **Step 6: Verify**

Headless: `node --input-type=module` importing every named export from the bundle
builds an `EditorState` with the extension set. Manual: open editor → YAML/Split
shows line numbers + colored YAML; toggle app theme → editor follows light/dark;
type YAML → structured mirrors it (split) and Save persists; caret/selection work.

- [ ] **Step 7: Commit**

```bash
git add web/config/importmap.rb web/vendor/javascript/codemirror.min.js \
        web/vendor/javascript/highlight/yaml.min.js \
        web/app/views/control_center/templates/index.html.erb \
        web/app/javascript/controllers/control_center_templates_controller.js
git commit -m "Replace the Control Center YAML pane with a vendored CodeMirror 6 editor"
```


---

## Self-Review Notes

- **Spec coverage:** Save keep-open + Save & close (Task 2); Split as a third toggle (Task 3); localStorage persistence (Task 3, key `hunter.cc.editorMode`); live bidirectional sync via dry-run endpoints (Tasks 1 + 4); `validate` enriched with `yaml` (Task 1); accepted tradeoffs (comment loss, debounce latency) are inherent to the design and need no task.
- **Dry-run guarantee:** sync uses only `validate`/`validate_yaml`; DB writes only in `_save` → create/update. ✓
- **Type consistency:** `lastEdited` values `"structured"|"yaml"`; `mode` values `"structured"|"yaml"|"split"`; both save buttons are enabled/disabled together (`saveTarget`, `saveCloseTarget`); `data.yaml` (Task 1) and `data.template` (existing) are the sync payloads. ✓
- **Manual-only frontend:** repo has no Stimulus test harness, so Tasks 2-4 use in-app verification; Task 1 is covered by an integration test.
