# Control Center Bulk Template Import — Design Spec

**Date:** 2026-07-23
**Status:** Approved
**Module:** Control Center templates

## Problem

The Control Center template editor can read one Whiterabbit `.yaml` or `.yml`
file into CodeMirror, but it has no direct import workflow and cannot process a
batch. Importing many templates requires loading and saving every file manually.
The page also provides no drag-and-drop affordance when files are dragged over
it.

## Goals

- Import one or many Whiterabbit YAML files directly as separate persisted
  templates.
- Accept files from a multi-select file picker or by dropping them anywhere on
  the Templates page.
- Show a clear drag-active overlay, per-file progress, and a final batch summary.
- Resolve template-name conflicts interactively with **Update**, **Update all**,
  **Skip**, and **Skip all**.
- Continue processing valid files when other files fail validation.
- Preserve the existing editor-local single-file upload for loading a draft into
  CodeMirror without immediately persisting it.

## Non-goals

- No multipart upload or server-side file storage; browsers continue to read file
  contents locally and send YAML as JSON.
- No new bulk API endpoint, route, database table, migration, or dependency.
- No atomic all-or-nothing transaction across a batch.
- No directory upload, archive extraction, import cancellation, or automatic
  renaming of conflicts.
- No changes to YAML schema validation, command validation, or template rendering.

## User experience

### Import entry points

Add an **Import YAML** button beside **New template** in the Templates list
toolbar. Its hidden file input has `multiple` and accepts `.yaml` and `.yml`.
Selecting one file through this list-level action still uses the direct importer;
the number of selected files does not change its behavior.

Keep the editor's existing **Upload .yaml** action unchanged. It remains a draft
authoring tool that loads one file into CodeMirror and waits for **Save**.

When a drag containing files enters the Templates page, show a fixed,
pointer-events-free overlay above the page: a softened dark backdrop, a prominent
dashed drop boundary, an upload icon, and the message **Drop YAML templates to
import**. Nested drag-enter/leave events are counted so the overlay does not
flicker while the pointer crosses page children. Dropping files prevents the
browser's default file-open navigation, hides the overlay, and starts the same
import path as the list-level file picker.

### Progress window

Starting an import opens a modal progress window. It lists every selected
filename with one current result:

- `waiting`
- `validating`
- `imported`
- `updated`
- `skipped`
- `failed`

Processing is sequential so row order, conflict prompts, and "all" decisions are
deterministic. The window cannot be closed while work is active. When all files
reach a terminal result, it shows imported, updated, skipped, and failed counts,
enables **Close**, and refreshes the templates table.

All filename, template-name, status, and error text is inserted with DOM
`textContent`; imported YAML can never inject markup.

### Conflict window

A valid file conflicts when its parsed YAML `name` matches a persisted template
or a template created earlier in the same batch. Processing pauses and the
progress window presents a modal conflict state naming the file and existing
template. The actions behave as follows:

- **Update** — PATCH this file's YAML into the existing template, then ask again
  on the next conflict.
- **Update all** — update this conflict and every remaining conflict in this
  batch without another prompt.
- **Skip** — leave this existing template unchanged, mark this file skipped, and
  ask again on the next conflict.
- **Skip all** — skip this conflict and every remaining conflict in this batch
  without another prompt.

An "all" choice applies only to the current batch and is discarded after it
finishes. If two files in one batch declare the same new name, the first creates
the template and the second is a conflict. Updating it means the later file wins.

## Architecture

### `TemplateBatchImporter`

Add a DOM-independent ES module under `web/app/javascript/lib/`. It owns batch
state and sequential orchestration, while receiving side effects as callbacks:

```javascript
new TemplateBatchImporter({
  validateYaml,
  createTemplate,
  updateTemplate,
  resolveConflict,
  onStatus,
  maxBytes: 64000,
}).run(files, existingTemplates)
```

`files` use the browser `File` interface (`name`, `size`, and `text()`).
`existingTemplates` is the latest API index array with at least `id` and `name`.
The callback contracts are:

- `validateYaml(yaml) -> Promise<{ ok, template?, errors? }>` where a successful
  `template` includes its normalized `name`;
- `createTemplate(yaml) -> Promise<{ ok, template?, errors? }>` where a
  successful `template` includes its persisted `id` and `name`;
- `updateTemplate(id, yaml) -> Promise<{ ok, template?, errors? }>`;
- `resolveConflict({ fileName, templateName, existing }) ->
  Promise<"update" | "update_all" | "skip" | "skip_all">`; and
- `onStatus(result)` where `result` has `{ index, fileName, templateName,
  status, errors }` and `status` is one of the progress-window states.

`run` resolves to the terminal per-file result array using the same result shape
and never manipulates the DOM.

This extraction keeps import orchestration out of the existing 518-line
`control_center_templates_controller.js` and allows behavior tests with Node's
built-in test runner and simple callback fakes.

### Stimulus controller

The existing `control-center-templates` controller remains the page coordinator.
It owns:

- file-picker and window drag/drop event handling;
- showing and hiding the drag overlay and progress window;
- safe DOM rendering of result rows and counts;
- a Promise-backed conflict resolver completed by the four conflict buttons;
- adapters from importer callbacks to `apiFetch`;
- fetching a fresh template index before every batch; and
- refreshing the visible table after the batch settles.

The list-level picker resets its value after every selection so choosing the same
files again still fires `change`. Drag state is also reset on drop, disconnect,
and a window-level drag leave.

### Existing Rails API

No server changes are required. Each file uses existing authenticated,
CSRF-protected JSON endpoints:

1. `POST /api/v1/control_center/templates/validate_yaml` with `{ yaml }`.
2. `POST /api/v1/control_center/templates` with `{ yaml }` for a new name.
3. `PATCH /api/v1/control_center/templates/:id` with `{ yaml }` after an update
   decision.

`ControlCenter::TemplateYaml` remains the YAML security boundary and enforces the
64,000-byte cap, safe parsing, strict schema, and normalization. Model validation
continues to enforce name uniqueness and command rules.

## Import flow

At batch start the controller fetches the current templates index and passes it
to the importer. The importer builds a mutable name-to-template map and processes
each file in selection order:

1. Reject a filename that does not end in `.yaml` or `.yml`, case-insensitively.
2. Reject a file larger than 64,000 bytes.
3. Read the content with `File.text()`; a read exception fails only that file.
4. Call `validate_yaml`; parser, schema, or command errors fail only that file.
5. Read the normalized template name from the validation response.
6. If the name is absent from the map, create it and add the returned `id` and
   name to the map.
7. If the name is present, obtain the current batch policy or await the conflict
   resolver, then update or skip.
8. Emit every state transition through `onStatus`.

The importer continues after client checks, reads, validation, create, or update
failures. An unexpected error is converted into that file's failed result rather
than rejecting the whole batch.

Because this is not a database transaction, users may see partial success. The
progress window makes that explicit and retains each error until it is closed.

## Error handling

- Unsupported extension: `Only .yaml and .yml files can be imported.`
- Oversized file: `File is too large (max 64 KB).`
- Browser read failure: report a concise read error.
- YAML/API validation failure: show the API's `errors` or `detail` messages on
  that file's row.
- Create/update failure: show the API detail when present, otherwise a stable
  `Import failed` or `Update failed` fallback.
- Initial index failure: open the progress window, mark every file failed with
  `Could not load existing templates`, and make no writes because conflict-safe
  behavior cannot be guaranteed without the current names and IDs.

## Testing

### Pure JavaScript behavior

Use Node's built-in `node:test` and `node:assert/strict`; do not add npm packages.
The `.mjs` test imports the syntax-detected ES module directly. Cover:

- several unique YAML files create separate templates in selection order;
- an invalid extension, oversized file, read failure, and validation failure do
  not stop later files;
- **Update** updates one conflict and prompts again for the next;
- **Skip** skips one conflict and prompts again for the next;
- **Update all** updates all remaining conflicts without more prompts;
- **Skip all** skips all remaining conflicts without more prompts;
- duplicate names inside one batch become conflicts using the newly created ID;
- create/update callback failures produce per-file failed results; and
- status transitions and final result counts are correct.

### Rails integration markup

Create a dedicated
`web/test/integration/control_center/template_import_test.rb` so concurrent work
on other Control Center tabs does not overlap `tabs_test.rb`. Assert that the
authenticated Templates page renders:

- the list-level input with `multiple`, YAML accept types, the batch-file target,
  and its import action;
- window drag/drop actions;
- the fixed drag overlay;
- the progress dialog and status-list target;
- the conflict panel and all four decision actions; and
- the final summary and close action.

Existing service and API tests continue to cover safe YAML parsing and individual
create/update behavior. No new Rails API test is needed because the API contract
does not change.

### Verification

Run the focused Node test, the focused Rails integration test, the existing
Control Center test directories, and the full Rails suite. In a browser, verify
the non-headless interaction that markup tests cannot prove: overlay stability,
drop prevention, modal focus, sequential conflict decisions, dark mode, and
responsive layout.

## Concurrent-work boundary

Another contributor is adding an unrelated Control Center tab concurrently.
This feature therefore avoids routes, `ControlCenter::BaseController::TABS`, and
the shared `control_center/tabs_test.rb`. Before each edit, inspect the worktree
and preserve unrelated changes. Expected implementation files are:

- `web/app/views/control_center/templates/index.html.erb`
- `web/app/javascript/controllers/control_center_templates_controller.js`
- `web/app/javascript/lib/template_batch_importer.js` (new)
- `web/test/javascript/template_batch_importer_test.mjs` (new)
- `web/test/integration/control_center/template_import_test.rb` (new)
