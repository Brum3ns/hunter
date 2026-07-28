# Control Center Bulk Template Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add direct multi-file YAML template imports with page-wide drag/drop, deterministic per-file progress, and interactive update/skip conflict handling.

**Architecture:** A DOM-independent `TemplateBatchImporter` performs sequential file validation and persistence through injected callbacks. The existing Control Center Templates Stimulus controller adapts those callbacks to the existing JSON API and owns only browser interaction and safe DOM rendering; Rails markup supplies the import button, drag overlay, progress dialog, and conflict controls.

**Tech Stack:** Rails 8.1, ERB, Tailwind CSS v4, importmap-rails, Stimulus, browser File API, Node 24 built-in `node:test`, Minitest integration tests.

## Global Constraints

- Import files directly only through the list-level **Import YAML** action or page-wide drop; preserve the editor's single-file **Upload .yaml** draft behavior.
- Accept `.yaml` and `.yml` case-insensitively and enforce the existing 64,000-byte per-file limit.
- Persist each valid file independently; one failure must not stop later files.
- Conflicts are based on normalized YAML template name and offer **Update**, **Update all**, **Skip**, and **Skip all**.
- An "all" decision lasts only for the active batch.
- Use only the existing template index, `validate_yaml`, create, and update endpoints; add no route, migration, API action, or dependency.
- Insert every file name, template name, error, and status with `textContent`.
- Do not touch Control Center routes, `ControlCenter::BaseController::TABS`, or `web/test/integration/control_center/tabs_test.rb`; another contributor is adding a separate tab concurrently.
- Re-read `git status --short` and diffs before each patch, preserving unrelated shared-worktree edits.
- Do not commit unless the user explicitly requests a commit.

## File Structure

- Create `web/app/javascript/lib/template_batch_importer.js`: sequential, DOM-free import state machine.
- Create `web/test/javascript/template_batch_importer_test.mjs`: Node behavior tests for validation, persistence, conflicts, error isolation, and status results.
- Modify `web/app/views/control_center/templates/index.html.erb`: list-level multi-picker, window drag wiring, overlay, progress dialog, and conflict UI.
- Modify `web/app/javascript/controllers/control_center_templates_controller.js`: drag/drop and modal coordinator plus adapters to `apiFetch`.
- Create `web/test/integration/control_center/template_import_test.rb`: authenticated server-rendered markup contract isolated from other Control Center tab tests.
- Update `docs/superpowers/specs/2026-07-23-control-center-bulk-template-import-design.md`: mark implemented after verification.

---

### Task 1: DOM-independent batch importer

**Files:**
- Create: `web/test/javascript/template_batch_importer_test.mjs`
- Create: `web/app/javascript/lib/template_batch_importer.js`

**Interfaces:**
- Consumes: browser-like files exposing `name: String`, `size: Number`, and `text() -> Promise<String>`; current templates shaped as `{ id, name }`.
- Produces: `new TemplateBatchImporter(callbacks).run(files, existingTemplates) -> Promise<Result[]>`, where `Result` is `{ index, fileName, templateName, status, errors }`.
- Callback decisions are exactly `"update"`, `"update_all"`, `"skip"`, or `"skip_all"`.

- [ ] **Step 1: Write the failing importer behavior tests**

Create `web/test/javascript/template_batch_importer_test.mjs`:

```javascript
import test from "node:test"
import assert from "node:assert/strict"
import { TemplateBatchImporter } from "../../app/javascript/lib/template_batch_importer.js"

function file(name, yaml, { size = Buffer.byteLength(yaml), readError = false } = {}) {
  return {
    name,
    size,
    async text() {
      if (readError) throw new Error("disk read failed")
      return yaml
    },
  }
}

function templateName(yaml) {
  return yaml.match(/^name:\s*(\S+)/m)?.[1]
}

function importer(overrides = {}) {
  let nextId = 100
  return new TemplateBatchImporter({
    maxBytes: 64000,
    validateYaml: async (yaml) => {
      if (yaml.includes("INVALID")) return { ok: false, errors: ["bad yaml"] }
      return { ok: true, template: { name: templateName(yaml) } }
    },
    createTemplate: async (yaml) => ({
      ok: true,
      template: { id: nextId++, name: templateName(yaml) },
    }),
    updateTemplate: async (id, yaml) => ({
      ok: true,
      template: { id, name: templateName(yaml) },
    }),
    resolveConflict: async () => "skip",
    onStatus: () => {},
    ...overrides,
  })
}

test("imports several unique files as separate templates in selection order", async () => {
  const created = []
  const statuses = []
  const subject = importer({
    createTemplate: async (yaml) => {
      created.push(templateName(yaml))
      return { ok: true, template: { id: created.length, name: templateName(yaml) } }
    },
    onStatus: (result) => statuses.push(`${result.fileName}:${result.status}`),
  })

  const results = await subject.run([
    file("alpha.yaml", "name: alpha\ncommands: []\n"),
    file("beta.yml", "name: beta\ncommands: []\n"),
  ], [])

  assert.deepEqual(created, ["alpha", "beta"])
  assert.deepEqual(results.map(({ fileName, templateName, status }) => ({ fileName, templateName, status })), [
    { fileName: "alpha.yaml", templateName: "alpha", status: "imported" },
    { fileName: "beta.yml", templateName: "beta", status: "imported" },
  ])
  assert.deepEqual(statuses, [
    "alpha.yaml:waiting", "beta.yml:waiting",
    "alpha.yaml:validating", "alpha.yaml:imported",
    "beta.yml:validating", "beta.yml:imported",
  ])
})

test("file and validation failures do not stop later imports", async () => {
  const created = []
  const results = await importer({
    createTemplate: async (yaml) => {
      created.push(templateName(yaml))
      return { ok: true, template: { id: 1, name: templateName(yaml) } }
    },
  }).run([
    file("notes.txt", "name: notes"),
    file("huge.yaml", "name: huge", { size: 64001 }),
    file("unreadable.yml", "name: unreadable", { readError: true }),
    file("invalid.yaml", "INVALID"),
    file("good.YML", "name: good\ncommands: []\n"),
  ], [])

  assert.deepEqual(results.map((result) => result.status), ["failed", "failed", "failed", "failed", "imported"])
  assert.match(results[0].errors[0], /\.yaml and \.yml/)
  assert.match(results[1].errors[0], /64 KB/)
  assert.equal(results[2].errors[0], "Could not read file.")
  assert.deepEqual(results[3].errors, ["bad yaml"])
  assert.deepEqual(created, ["good"])
})

test("update and skip resolve individual conflicts independently", async () => {
  const decisions = ["update", "skip"]
  const prompts = []
  const updated = []
  const subject = importer({
    resolveConflict: async (conflict) => {
      prompts.push(conflict.templateName)
      return decisions.shift()
    },
    updateTemplate: async (id, yaml) => {
      updated.push(id)
      return { ok: true, template: { id, name: templateName(yaml) } }
    },
  })

  const results = await subject.run([
    file("alpha.yaml", "name: alpha"),
    file("beta.yaml", "name: beta"),
  ], [{ id: 10, name: "alpha" }, { id: 20, name: "beta" }])

  assert.deepEqual(prompts, ["alpha", "beta"])
  assert.deepEqual(updated, [10])
  assert.deepEqual(results.map((result) => result.status), ["updated", "skipped"])
})

for (const policy of ["update_all", "skip_all"]) {
  test(`${policy} applies to every remaining conflict without another prompt`, async () => {
    let promptCount = 0
    const updated = []
    const subject = importer({
      resolveConflict: async () => { promptCount += 1; return policy },
      updateTemplate: async (id, yaml) => {
        updated.push(id)
        return { ok: true, template: { id, name: templateName(yaml) } }
      },
    })

    const results = await subject.run([
      file("alpha.yaml", "name: alpha"),
      file("beta.yaml", "name: beta"),
    ], [{ id: 10, name: "alpha" }, { id: 20, name: "beta" }])

    assert.equal(promptCount, 1)
    assert.deepEqual(
      results.map((result) => result.status),
      policy === "update_all" ? ["updated", "updated"] : ["skipped", "skipped"],
    )
    assert.deepEqual(updated, policy === "update_all" ? [10, 20] : [])
  })
}

test("a duplicate name created earlier in the batch becomes a conflict", async () => {
  const updated = []
  let prompt
  const subject = importer({
    createTemplate: async (yaml) => ({ ok: true, template: { id: 77, name: templateName(yaml) } }),
    resolveConflict: async (conflict) => { prompt = conflict; return "update" },
    updateTemplate: async (id, yaml) => {
      updated.push(id)
      return { ok: true, template: { id, name: templateName(yaml) } }
    },
  })

  const results = await subject.run([
    file("first.yaml", "name: repeated"),
    file("second.yaml", "name: repeated"),
  ], [])

  assert.equal(prompt.existing.id, 77)
  assert.deepEqual(updated, [77])
  assert.deepEqual(results.map((result) => result.status), ["imported", "updated"])
})

test("create and update callback failures remain per-file results", async () => {
  const subject = importer({
    createTemplate: async () => ({ ok: false, errors: ["create rejected"] }),
    resolveConflict: async () => "update",
    updateTemplate: async () => { throw new Error("network gone") },
  })

  const results = await subject.run([
    file("new.yaml", "name: new"),
    file("old.yaml", "name: old"),
  ], [{ id: 9, name: "old" }])

  assert.deepEqual(results.map((result) => result.status), ["failed", "failed"])
  assert.deepEqual(results[0].errors, ["create rejected"])
  assert.deepEqual(results[1].errors, ["Update failed."])
})

test("a conflict resolver failure does not stop later files", async () => {
  const created = []
  const subject = importer({
    resolveConflict: async () => { throw new Error("dialog disappeared") },
    createTemplate: async (yaml) => {
      created.push(templateName(yaml))
      return { ok: true, template: { id: 42, name: templateName(yaml) } }
    },
  })

  const results = await subject.run([
    file("old.yaml", "name: old"),
    file("new.yaml", "name: new"),
  ], [{ id: 9, name: "old" }])

  assert.deepEqual(results.map((result) => result.status), ["failed", "imported"])
  assert.deepEqual(results[0].errors, ["Could not resolve template conflict."])
  assert.deepEqual(created, ["new"])
})
```

- [ ] **Step 2: Run the Node test to verify RED**

Run from `web/`:

```bash
node --test test/javascript/template_batch_importer_test.mjs
```

Expected: FAIL with `ERR_MODULE_NOT_FOUND` for `app/javascript/lib/template_batch_importer.js`.

- [ ] **Step 3: Implement the importer state machine**

Create `web/app/javascript/lib/template_batch_importer.js`:

```javascript
const YAML_EXTENSION = /\.ya?ml$/i

export class TemplateBatchImporter {
  constructor({ validateYaml, createTemplate, updateTemplate, resolveConflict, onStatus, maxBytes = 64000 }) {
    this.validateYaml = validateYaml
    this.createTemplate = createTemplate
    this.updateTemplate = updateTemplate
    this.resolveConflict = resolveConflict
    this.onStatus = onStatus
    this.maxBytes = maxBytes
  }

  async run(files, existingTemplates) {
    this.conflictPolicy = null
    const byName = new Map(existingTemplates.map((template) => [template.name, template]))
    const results = Array.from(files).map((file, index) => ({
      index,
      fileName: file.name,
      templateName: null,
      status: "waiting",
      errors: [],
    }))

    results.forEach((result) => this.emit(result))
    for (const [index, file] of Array.from(files).entries()) {
      await this.processFile(file, results[index], byName)
    }
    return results
  }

  async processFile(file, result, byName) {
    if (!YAML_EXTENSION.test(file.name)) {
      return this.fail(result, "Only .yaml and .yml files can be imported.")
    }
    if (file.size > this.maxBytes) {
      return this.fail(result, "File is too large (max 64 KB).")
    }

    this.emit(result, { status: "validating", errors: [] })
    let yaml
    try {
      yaml = await file.text()
    } catch {
      return this.fail(result, "Could not read file.")
    }

    let validation
    try {
      validation = await this.validateYaml(yaml)
    } catch {
      return this.fail(result, "Validation request failed.")
    }
    if (!validation?.ok) return this.fail(result, this.errors(validation?.errors, "Validation failed."))

    const templateName = validation.template?.name
    if (!templateName) return this.fail(result, "Validated YAML did not include a template name.")
    result.templateName = templateName

    const existing = byName.get(templateName)
    if (existing) return this.handleConflict({ file, yaml, result, existing, byName })

    let created
    try {
      created = await this.createTemplate(yaml)
    } catch {
      return this.fail(result, "Import failed.")
    }
    if (!created?.ok) return this.fail(result, this.errors(created?.errors, "Import failed."))
    if (!created.template?.id) return this.fail(result, "Import response did not include a template ID.")

    byName.set(templateName, created.template)
    this.emit(result, { status: "imported", errors: [] })
  }

  async handleConflict({ file, yaml, result, existing, byName }) {
    let action = this.conflictPolicy
    if (!action) {
      let decision
      try {
        decision = await this.resolveConflict({
          fileName: file.name,
          templateName: result.templateName,
          existing,
        })
      } catch {
        return this.fail(result, "Could not resolve template conflict.")
      }
      if (decision === "update_all") this.conflictPolicy = "update"
      if (decision === "skip_all") this.conflictPolicy = "skip"
      action = decision === "update_all" ? "update" : decision === "skip_all" ? "skip" : decision
    }

    if (action !== "update") {
      this.emit(result, { status: "skipped", errors: [] })
      return
    }

    let updated
    try {
      updated = await this.updateTemplate(existing.id, yaml)
    } catch {
      return this.fail(result, "Update failed.")
    }
    if (!updated?.ok) return this.fail(result, this.errors(updated?.errors, "Update failed."))

    byName.set(result.templateName, updated.template || existing)
    this.emit(result, { status: "updated", errors: [] })
  }

  fail(result, errors) {
    this.emit(result, { status: "failed", errors: this.errors(errors, "Import failed.") })
  }

  errors(value, fallback) {
    if (Array.isArray(value)) {
      const errors = value.map(String).filter(Boolean)
      return errors.length ? errors : [fallback]
    }
    if (value) return [String(value)]
    return [fallback]
  }

  emit(result, changes = {}) {
    Object.assign(result, changes)
    this.onStatus({ ...result, errors: [...result.errors] })
  }
}
```

- [ ] **Step 4: Run the importer tests to verify GREEN**

Run:

```bash
node --test test/javascript/template_batch_importer_test.mjs
```

Expected: 8 tests pass, 0 fail.

- [ ] **Step 5: Review the task boundary without committing**

Run:

```bash
git diff --check -- web/app/javascript/lib/template_batch_importer.js web/test/javascript/template_batch_importer_test.mjs
git status --short
```

Expected: no whitespace errors; only the approved spec/plan, the two new importer files, `.claude/`, and any clearly unrelated concurrent files appear. Do not stage or commit.

---

### Task 2: Multi-picker, drag overlay, progress dialog, and conflict interaction

**Files:**
- Create: `web/test/integration/control_center/template_import_test.rb`
- Modify: `web/app/views/control_center/templates/index.html.erb`
- Modify: `web/app/javascript/controllers/control_center_templates_controller.js`

**Interfaces:**
- Consumes: `TemplateBatchImporter`, `apiFetch`, the existing `indexUrlValue` and `validateYamlUrlValue`, plus existing template CRUD URLs.
- Produces: Stimulus actions `batchFilesSelected`, `dragEnter`, `dragOver`, `dragLeave`, `dropFiles`, `dragEnd`, `chooseImportConflict`, `preventImportClose`, and `closeImport`.
- Produces targets `batchFileInput`, `dropOverlay`, `importDialog`, `importRows`, `importSummary`, `importClose`, `conflictPanel`, `conflictFile`, and `conflictName`.

- [ ] **Step 1: Write the failing authenticated markup contract**

Create `web/test/integration/control_center/template_import_test.rb`:

```ruby
require "test_helper"

class ControlCenter::TemplateImportTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:one))
    get control_center_root_path
  end

  test "renders a list-level multiple YAML picker" do
    assert_response :success
    assert_select "label", text: /Import YAML/
    assert_select "input[type=file][multiple][data-control-center-templates-target=batchFileInput]" do |inputs|
      input = inputs.first
      assert_includes input["accept"], ".yaml"
      assert_includes input["accept"], ".yml"
      assert_includes input["data-action"], "control-center-templates#batchFilesSelected"
    end
  end

  test "wires page-wide file drag and drop" do
    section = css_select("section[data-controller~='control-center-templates']").first
    actions = section["data-action"].split
    assert_includes actions, "dragenter@window->control-center-templates#dragEnter"
    assert_includes actions, "dragover@window->control-center-templates#dragOver"
    assert_includes actions, "dragleave@window->control-center-templates#dragLeave"
    assert_includes actions, "drop@window->control-center-templates#dropFiles"
    assert_includes actions, "dragend@window->control-center-templates#dragEnd"
    assert_select "[data-control-center-templates-target=dropOverlay]", text: /Drop YAML templates to import/
  end

  test "renders progress and all conflict decisions" do
    assert_select "dialog[data-control-center-templates-target=importDialog]" do
      assert_select "[data-control-center-templates-target=importRows]"
      assert_select "[data-control-center-templates-target=importSummary]"
      assert_select "button[data-control-center-templates-target=importClose][data-action='control-center-templates#closeImport']"
      assert_select "[data-control-center-templates-target=conflictPanel]" do
        %w[update update_all skip skip_all].each do |decision|
          assert_select "button[data-decision='#{decision}'][data-action='control-center-templates#chooseImportConflict']", count: 1
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run the Rails integration test to verify RED**

Run from `web/`:

```bash
bin/rails test test/integration/control_center/template_import_test.rb
```

Expected: 3 failures because the batch picker, window drag actions, overlay, and import dialog are absent.

- [ ] **Step 3: Add the list-level picker and page-wide drag wiring**

In `web/app/views/control_center/templates/index.html.erb`, extend the opening `<section>` with this `data-action` attribute while preserving its existing endpoint values:

```erb
<section class="mt-6"
         data-controller="control-center-templates"
         data-action="dragenter@window->control-center-templates#dragEnter dragover@window->control-center-templates#dragOver dragleave@window->control-center-templates#dragLeave drop@window->control-center-templates#dropFiles dragend@window->control-center-templates#dragEnd"
         data-control-center-templates-index-url-value="<%= api_v1_control_center_templates_path %>"
         data-control-center-templates-validate-url-value="<%= validate_api_v1_control_center_templates_path %>"
         data-control-center-templates-jobs-url-value="<%= api_v1_control_center_jobs_path %>"
         data-control-center-templates-validate-yaml-url-value="<%= validate_yaml_api_v1_control_center_templates_path %>">
```

Replace the toolbar's standalone **New template** button with a right-side group containing the batch picker and the unchanged button:

```erb
<div class="flex flex-wrap items-center gap-2">
  <label class="inline-flex cursor-pointer items-center gap-1.5 rounded-md border border-zinc-300 px-3 py-1.5 text-sm font-medium text-zinc-700 hover:bg-zinc-100 focus-within:ring-2 focus-within:ring-zinc-400 focus-within:ring-offset-2 dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800 dark:focus-within:ring-zinc-500 dark:focus-within:ring-offset-[#0a0a0a]">
    <%= heroicon "arrow-up-tray", classes: "h-4 w-4" %> Import YAML
    <input type="file" multiple accept=".yaml,.yml,text/yaml,application/yaml" class="sr-only"
           data-control-center-templates-target="batchFileInput"
           data-action="change->control-center-templates#batchFilesSelected">
  </label>
  <button type="button" data-action="control-center-templates#newTemplate"
          class="inline-flex items-center gap-1.5 rounded-md bg-zinc-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-zinc-700 dark:bg-white dark:text-zinc-900 dark:hover:bg-zinc-200">
    New template
  </button>
</div>
```

- [ ] **Step 4: Add the drag overlay and import dialog markup**

Immediately before the closing `</section>`, after the existing send-job dialog, add:

```erb
<div data-control-center-templates-target="dropOverlay" aria-hidden="true"
     class="pointer-events-none fixed inset-0 z-[60] hidden bg-zinc-950/55 p-5 backdrop-blur-sm">
  <div class="flex h-full items-center justify-center rounded-2xl border-2 border-dashed border-white/70 bg-zinc-950/30">
    <div class="rounded-2xl border border-white/15 bg-zinc-950/80 px-10 py-9 text-center text-white shadow-2xl">
      <div class="mx-auto flex h-14 w-14 items-center justify-center rounded-full bg-white/10">
        <%= heroicon "arrow-up-tray", classes: "h-7 w-7" %>
      </div>
      <p class="mt-4 text-lg font-semibold">Drop YAML templates to import</p>
      <p class="mt-1 text-sm text-zinc-300">Each .yaml or .yml file becomes a separate template.</p>
    </div>
  </div>
</div>

<dialog data-control-center-templates-target="importDialog"
        data-action="cancel->control-center-templates#preventImportClose"
        class="fixed inset-0 z-[70] m-auto w-[min(42rem,calc(100vw-2rem))] overflow-hidden rounded-xl border border-zinc-200 bg-white p-0 text-zinc-900 shadow-2xl backdrop:bg-zinc-950/60 dark:border-zinc-700 dark:bg-[#111315] dark:text-zinc-100">
  <div class="border-b border-zinc-200 px-5 py-4 dark:border-zinc-800">
    <h2 class="text-base font-semibold">Import YAML templates</h2>
    <p class="mt-1 text-sm text-zinc-500 dark:text-zinc-400">Files are validated and imported in selection order.</p>
  </div>

  <div class="max-h-[55vh] overflow-y-auto px-5 py-4">
    <ul data-control-center-templates-target="importRows" aria-live="polite" class="space-y-2"></ul>

    <div data-control-center-templates-target="conflictPanel" role="alertdialog" aria-label="Template name conflict" aria-live="assertive"
         class="mt-4 hidden rounded-lg border border-amber-300 bg-amber-50 p-4 dark:border-amber-700/70 dark:bg-amber-950/30">
      <p class="text-sm font-semibold text-amber-950 dark:text-amber-100">Template name conflict</p>
      <p class="mt-1 text-sm text-amber-900 dark:text-amber-200">
        <span data-control-center-templates-target="conflictFile" class="font-mono"></span>
        matches <span data-control-center-templates-target="conflictName" class="font-semibold"></span>.
      </p>
      <div class="mt-3 flex flex-wrap gap-2">
        <button type="button" data-decision="update" data-action="control-center-templates#chooseImportConflict"
                class="rounded-md bg-amber-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-amber-800 dark:bg-amber-200 dark:text-amber-950 dark:hover:bg-amber-100">Update</button>
        <button type="button" data-decision="update_all" data-action="control-center-templates#chooseImportConflict"
                class="rounded-md border border-amber-400 px-3 py-1.5 text-sm font-medium text-amber-950 hover:bg-amber-100 dark:border-amber-700 dark:text-amber-100 dark:hover:bg-amber-900/40">Update all</button>
        <button type="button" data-decision="skip" data-action="control-center-templates#chooseImportConflict"
                class="rounded-md border border-zinc-300 px-3 py-1.5 text-sm font-medium text-zinc-700 hover:bg-white dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800">Skip</button>
        <button type="button" data-decision="skip_all" data-action="control-center-templates#chooseImportConflict"
                class="rounded-md border border-zinc-300 px-3 py-1.5 text-sm font-medium text-zinc-700 hover:bg-white dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800">Skip all</button>
      </div>
    </div>

    <p data-control-center-templates-target="importSummary" aria-live="polite"
       class="mt-4 hidden rounded-md bg-zinc-100 px-3 py-2 text-sm text-zinc-700 dark:bg-zinc-800 dark:text-zinc-200"></p>
  </div>

  <div class="flex justify-end border-t border-zinc-200 px-5 py-3 dark:border-zinc-800">
    <button type="button" disabled data-control-center-templates-target="importClose"
            data-action="control-center-templates#closeImport"
            class="rounded-md bg-zinc-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-zinc-700 disabled:cursor-not-allowed disabled:opacity-40 dark:bg-white dark:text-zinc-900 dark:hover:bg-zinc-200">Close</button>
  </div>
</dialog>
```

- [ ] **Step 5: Wire the importer into the Stimulus controller**

At the top of `web/app/javascript/controllers/control_center_templates_controller.js`, add the importer beside `apiFetch`:

```javascript
import { TemplateBatchImporter } from "lib/template_batch_importer"
```

Append these names to `static targets`:

```javascript
"batchFileInput", "dropOverlay", "importDialog", "importRows", "importSummary", "importClose",
"conflictPanel", "conflictFile", "conflictName",
```

At the end of `connect()`, initialize batch UI state:

```javascript
this._dragDepth = 0
this._importActive = false
this._importRowViews = new Map()
this._pendingConflict = null
```

At the end of `disconnect()`, reset drag state and release a conflict Promise if Turbo removes the page:

```javascript
this._dragDepth = 0
this.dropOverlayTarget.classList.add("hidden")
if (this._pendingConflict) this._pendingConflict("skip_all")
this._pendingConflict = null
```

Add the following focused import section before the existing `// --- editor` section:

```javascript
  // --- batch YAML import ---------------------------------------------------

  batchFilesSelected(event) {
    const files = Array.from(event.target.files || [])
    event.target.value = ""
    this.startBatchImport(files)
  }

  dragEnter(event) {
    if (!this._isFileDrag(event)) return
    event.preventDefault()
    this._dragDepth += 1
    this.dropOverlayTarget.classList.remove("hidden")
  }

  dragOver(event) {
    if (!this._isFileDrag(event)) return
    event.preventDefault()
    if (event.dataTransfer) event.dataTransfer.dropEffect = "copy"
  }

  dragLeave(event) {
    if (this._dragDepth === 0) return
    this._dragDepth = Math.max(0, this._dragDepth - 1)
    if (this._dragDepth === 0) this.dropOverlayTarget.classList.add("hidden")
  }

  dropFiles(event) {
    if (!this._isFileDrag(event)) return
    event.preventDefault()
    const files = Array.from(event.dataTransfer?.files || [])
    this.dragEnd()
    this.startBatchImport(files)
  }

  dragEnd() {
    this._dragDepth = 0
    this.dropOverlayTarget.classList.add("hidden")
  }

  _isFileDrag(event) {
    return Array.from(event.dataTransfer?.types || []).includes("Files")
  }

  async startBatchImport(files) {
    if (!files.length || this._importActive) return
    this._importActive = true
    this._openImportDialog(files)

    const indexResponse = await apiFetch(this.indexUrlValue)
    if (!indexResponse.ok || !Array.isArray(indexResponse.data?.templates)) {
      const results = files.map((file, index) => ({
        index,
        fileName: file.name,
        templateName: null,
        status: "failed",
        errors: ["Could not load existing templates."],
      }))
      results.forEach((result) => this._renderImportStatus(result))
      this._finishImport(results)
      return
    }

    const importer = new TemplateBatchImporter({
      maxBytes: 64000,
      validateYaml: (yaml) => this._validateImportYaml(yaml),
      createTemplate: (yaml) => this._createImportedTemplate(yaml),
      updateTemplate: (id, yaml) => this._updateImportedTemplate(id, yaml),
      resolveConflict: (conflict) => this._resolveImportConflict(conflict),
      onStatus: (result) => this._renderImportStatus(result),
    })

    const results = await importer.run(files, indexResponse.data.templates)
    await this.refresh()
    this._finishImport(results)
  }

  _openImportDialog(files) {
    this.importRowsTarget.replaceChildren()
    this.importSummaryTarget.classList.add("hidden")
    this.importSummaryTarget.textContent = ""
    this.importCloseTarget.disabled = true
    this.conflictPanelTarget.classList.add("hidden")
    this._importRowViews = new Map()

    files.forEach((file, index) => {
      const row = document.createElement("li")
      row.className = "rounded-lg border border-zinc-200 px-3 py-2 dark:border-zinc-800"

      const line = document.createElement("div")
      line.className = "flex items-center gap-3"
      const name = document.createElement("span")
      name.className = "min-w-0 flex-1 truncate font-mono text-sm"
      name.textContent = file.name
      const badge = document.createElement("span")
      badge.className = this._importBadgeClasses("waiting")
      badge.textContent = "waiting"
      line.append(name, badge)

      const detail = document.createElement("p")
      detail.className = "mt-1 hidden text-xs text-zinc-500 dark:text-zinc-400"
      row.append(line, detail)
      this.importRowsTarget.appendChild(row)
      this._importRowViews.set(index, { badge, detail })
    })

    if (!this.importDialogTarget.open) this.importDialogTarget.showModal()
  }

  _renderImportStatus(result) {
    const view = this._importRowViews.get(result.index)
    if (!view) return
    view.badge.textContent = result.status
    view.badge.className = this._importBadgeClasses(result.status)
    const details = []
    if (result.templateName) details.push(result.templateName)
    if (result.errors?.length) details.push(result.errors.join("; "))
    view.detail.textContent = details.join(" — ")
    view.detail.classList.toggle("hidden", details.length === 0)
  }

  _importBadgeClasses(status) {
    const base = "shrink-0 rounded px-2 py-0.5 text-xs font-medium"
    const colors = {
      waiting: "bg-zinc-100 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300",
      validating: "bg-sky-100 text-sky-700 dark:bg-sky-950/50 dark:text-sky-300",
      imported: "bg-emerald-100 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-300",
      updated: "bg-emerald-100 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-300",
      skipped: "bg-amber-100 text-amber-800 dark:bg-amber-950/50 dark:text-amber-300",
      failed: "bg-rose-100 text-rose-700 dark:bg-rose-950/50 dark:text-rose-300",
    }
    return `${base} ${colors[status] || colors.waiting}`
  }

  async _validateImportYaml(yaml) {
    const { ok, data } = await apiFetch(this.validateYamlUrlValue, { method: "POST", body: { yaml } })
    const valid = ok && data?.valid
    return {
      ok: valid,
      template: data?.template,
      errors: valid ? [] : this._importApiErrors(data, "Validation failed."),
    }
  }

  async _createImportedTemplate(yaml) {
    const { ok, data } = await apiFetch(this.indexUrlValue, { method: "POST", body: { yaml } })
    return { ok, template: ok ? data : null, errors: ok ? [] : this._importApiErrors(data, "Import failed.") }
  }

  async _updateImportedTemplate(id, yaml) {
    const { ok, data } = await apiFetch(`${this.indexUrlValue}/${id}`, { method: "PATCH", body: { yaml } })
    return { ok, template: ok ? data : null, errors: ok ? [] : this._importApiErrors(data, "Update failed.") }
  }

  _importApiErrors(data, fallback) {
    const errors = data?.errors || data?.detail
    if (Array.isArray(errors)) return errors.map(String)
    return errors ? [String(errors)] : [fallback]
  }

  _resolveImportConflict({ fileName, templateName, existing }) {
    this.conflictFileTarget.textContent = fileName
    this.conflictNameTarget.textContent = templateName
    this.conflictPanelTarget.classList.remove("hidden")
    this.conflictPanelTarget.scrollIntoView({ block: "nearest" })
    this.conflictPanelTarget.querySelector("button")?.focus()
    return new Promise((resolve) => {
      this._pendingConflict = resolve
      this._pendingConflictExisting = existing
    })
  }

  chooseImportConflict(event) {
    if (!this._pendingConflict) return
    const resolve = this._pendingConflict
    this._pendingConflict = null
    this._pendingConflictExisting = null
    this.conflictPanelTarget.classList.add("hidden")
    resolve(event.currentTarget.dataset.decision)
  }

  _finishImport(results) {
    const counts = { imported: 0, updated: 0, skipped: 0, failed: 0 }
    results.forEach((result) => { if (result.status in counts) counts[result.status] += 1 })
    this.importSummaryTarget.textContent =
      `Imported ${counts.imported} · Updated ${counts.updated} · Skipped ${counts.skipped} · Failed ${counts.failed}`
    this.importSummaryTarget.classList.remove("hidden")
    this.importCloseTarget.disabled = false
    this._importActive = false
    this.importCloseTarget.focus()
  }

  preventImportClose(event) {
    if (this._importActive) event.preventDefault()
  }

  closeImport() {
    if (!this._importActive) this.importDialogTarget.close()
  }
```

- [ ] **Step 6: Run focused behavior, markup, and syntax checks to verify GREEN**

Run from `web/`:

```bash
node --test test/javascript/template_batch_importer_test.mjs
node --check app/javascript/controllers/control_center_templates_controller.js
bin/rails test test/integration/control_center/template_import_test.rb
```

Expected: 8 Node tests pass, JavaScript syntax check exits 0, and 3 Rails integration tests pass.

- [ ] **Step 7: Re-run the existing Templates shell integration test**

Run:

```bash
bin/rails test test/integration/control_center/tabs_test.rb
```

Expected: all existing Control Center tab tests pass, including the editor-local single-file upload assertion.

- [ ] **Step 8: Review the task boundary without committing**

Run:

```bash
git diff --check -- web/app/views/control_center/templates/index.html.erb web/app/javascript/controllers/control_center_templates_controller.js web/app/javascript/lib/template_batch_importer.js web/test/javascript/template_batch_importer_test.mjs web/test/integration/control_center/template_import_test.rb
git status --short
```

Expected: no whitespace errors and no edits to routes, the tab registry, or `tabs_test.rb`. Do not stage or commit.

---

### Task 3: Regression verification and handoff

**Files:**
- Modify: `docs/superpowers/specs/2026-07-23-control-center-bulk-template-import-design.md`

**Interfaces:**
- Consumes: the complete importer and UI from Tasks 1–2.
- Produces: verified Control Center behavior and an implementation-status update in the approved spec.

- [ ] **Step 1: Run all Control Center tests**

Run from `web/`:

```bash
bin/rails test test/services/control_center test/models/control_center test/integration/api/v1/control_center test/integration/control_center
```

Expected: all Control Center service, model, API, and web integration tests pass.

- [ ] **Step 2: Build assets to verify importmap and Tailwind integration**

Run:

```bash
bin/rails assets:precompile
```

Expected: exit 0; `lib/template_batch_importer` resolves through the existing `pin_all_from "app/javascript/lib"`, and Tailwind compiles all new ERB/JS utility classes.

- [ ] **Step 3: Run the full Rails suite**

Run:

```bash
bin/rails test
```

Expected: the full suite passes with 0 failures and 0 errors. If unrelated concurrent work causes a failure, capture the exact test and determine ownership before editing another contributor's files.

- [ ] **Step 4: Verify the browser interaction**

With the development app open on `/control_center`, perform this exact check:

1. Drag a `.yaml` file over several child elements; the full-page overlay remains stable and disappears when leaving the window.
2. Drop two uniquely named valid files; both progress rows finish `imported`, the summary says `Imported 2`, and both table rows appear.
3. Drop one invalid file together with one valid file; the invalid row finishes `failed` with its API validation message and the valid row still imports.
4. Drop files whose names conflict with two existing templates; choose **Update** then **Skip** and confirm one updates and one remains unchanged.
5. Repeat with **Update all**, then with **Skip all**, confirming only one prompt appears for each batch.
6. Open **New template**, use the editor-local **Upload .yaml**, and confirm it still loads CodeMirror without persisting until **Save**.
7. Repeat the dialog and overlay check in dark mode and at a narrow viewport.

Expected: all seven checks behave as described, with no browser console errors and no browser navigation on drop.

- [ ] **Step 5: Mark the design implemented**

Change the spec header in `docs/superpowers/specs/2026-07-23-control-center-bulk-template-import-design.md` from:

```markdown
**Status:** Approved
```

to:

```markdown
**Status:** Implemented
```

- [ ] **Step 6: Inspect the final shared-worktree diff without committing**

Run from the repository root:

```bash
git diff --check
git status --short
git diff -- docs/superpowers/specs/2026-07-23-control-center-bulk-template-import-design.md docs/superpowers/plans/2026-07-23-control-center-bulk-template-import.md web/app/views/control_center/templates/index.html.erb web/app/javascript/controllers/control_center_templates_controller.js web/app/javascript/lib/template_batch_importer.js web/test/javascript/template_batch_importer_test.mjs web/test/integration/control_center/template_import_test.rb
```

Expected: only the approved bulk-import files appear in the scoped diff, while unrelated concurrent files remain untouched. Do not stage or commit.
