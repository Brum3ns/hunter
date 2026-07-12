# Control Center template editor: save modes + live split view

**Date:** 2026-07-12
**Status:** Approved (pending spec review)
**Module:** Control Center (web department)

## Problem

The Control Center template editor has two friction points when authoring jobs:

1. **Save always closes the editor.** There is no way to save progress and keep
   working — every save collapses the panel, forcing a re-open (Edit) to continue.
2. **Structured and YAML are mutually exclusive tabs.** You can view *either* the
   structured form *or* the raw YAML, never both, and switching tabs does not
   convert between them. For an unsaved template the YAML tab is simply empty.
   Iterating on a job means mentally translating between the two representations.

## Goals

- A **Save** button that persists but keeps the editor open, alongside the
  existing close-on-save action (renamed **Save & close**).
- A **Split** view showing the structured form and the YAML side by side, where
  editing either side live-updates the other.
- Live sync is a **UI-only** convenience for developing jobs. It never writes to
  the database — persistence happens *only* on Save / Save & close.
- The chosen editor mode (Structured / YAML / Split) is remembered per browser so
  the user does not re-select Split on every session.
- The YAML pane is a proper **code editor** — syntax highlighting as you type,
  line numbers, and light/dark theming that follows the app's theme toggle.

## Non-goals

- Preserving YAML comments / formatting across a structured-side edit (see
  Tradeoffs).
- Cross-device preference sync (localStorage is per-browser, by decision).
- Any change to the persistence model, validation rules, or the command
  allowlist.

## Current architecture (baseline)

- View: `web/app/views/control_center/templates/index.html.erb` — an editor panel
  with a `structuredPanel` and a `yamlPanel`, toggled by Structured/YAML buttons.
- Stimulus controller: `web/app/javascript/controllers/control_center_templates_controller.js`
  — `mode` is `"structured" | "yaml"`; `showStructured`/`showYaml` flip panel
  visibility; `save()` posts and then always `closeEditor()`.
- API: `web/app/controllers/api/v1/control_center/templates_controller.rb`
  - `validate` (POST, dry-run) — takes `commands`, returns `{ valid, errors }`.
  - `validate_yaml` (POST, dry-run) — takes `yaml`, returns
    `{ valid, errors, template }` where `template` is the parsed structured attrs.
  - CRUD create/update accept either structured params or a `yaml` param.
  - `serialize` renders `yaml` via `ControlCenter::TemplateRenderer` for persisted
    templates only.

**Key finding:** the YAML→structured direction already exists (`validate_yaml`
returns `template`). The structured→YAML direction has no dry-run endpoint — only
persisted templates get rendered YAML. This is the one server gap to close.

## Design

### 1. Save modes

Replace the single Save button with two:

- **Save** — persists, then refreshes the list, keeps the editor open, and shows a
  transient "Saved" indicator.
- **Save & close** — persists, refreshes the list, and closes the editor
  (today's behavior).

The controller's `save()` is refactored to `save({ close })`; two thin actions
(`save` and `saveAndClose`) delegate to it. Critical detail: when a *new*
template is saved with the editor kept open, the response `id` is captured into
`this.editingId`, so subsequent saves become `PATCH` updates instead of creating
duplicate records. The save payload is chosen from `lastEdited` (see §3): YAML
text when the user last edited YAML, structured params otherwise.

### 2. Split as a third mode

`mode` becomes `"structured" | "yaml" | "split"`, driven by a three-way toggle
(Structured | YAML | Split).

- Structured: only `structuredPanel` visible.
- YAML: only `yamlPanel` visible.
- Split: both panels visible in a responsive two-column layout
  (`grid lg:grid-cols-2 gap-4`, stacked single-column below the `lg` breakpoint).

No new panels — the existing `structuredPanel`/`yamlPanel` are reused; the mode
only controls visibility and the wrapping layout classes.

The active mode is written to `localStorage` (key `hunter.cc.editorMode`) on every
switch and read on `connect()`; when the editor opens, the stored mode is applied
(default `"structured"` when unset).

### 3. Live bidirectional sync (UI-only, dry-run)

Conversion stays server-side: the YAML parse is a deliberate security boundary
(`safe_load`), and the grouping/quoting render logic lives in `TemplateRenderer`
— duplicating either in JS would risk drift. Both directions reuse the existing
**dry-run** endpoints; only one needs enriching:

- **Structured → YAML:** extend the `validate` action to also return a rendered
  `yaml` string, built from the full structured params via
  `TemplateRenderer.to_yaml`. The debounced call that already fires on structured
  edits now returns validation errors *and* the YAML preview, which is written
  into the YAML textarea.
- **YAML → Structured:** the debounced `validate_yaml` call already returns
  `template` attrs; on YAML edits those attrs repopulate the structured fields and
  rebuild the command rows. Structured fields are only overwritten when
  `template` is present (i.e. the YAML parsed), so an in-progress invalid YAML
  does not wipe the form.

Sync mechanics:

- Runs on the existing ~300ms debounce; the cross-population step only executes in
  Split mode (single modes keep today's behavior plus the on-switch conversion
  below).
- **Loop safety:** programmatically assigning `.value` / rebuilding rows does not
  dispatch `input` events, so no echo loop occurs. A `this._syncing` guard wraps
  programmatic updates as belt-and-suspenders against re-entrant validation.
- `this.lastEdited` (`"structured" | "yaml"`) tracks the authoritative side and
  is set by the respective input handlers; it drives the save payload choice.
- **On mode switch** (also covering the single-tab gap): switching *into* YAML or
  Split regenerates YAML from structured if structured was last edited; switching
  *into* Structured or Split repopulates structured from YAML if YAML was last
  edited. This fixes the current empty-YAML-tab-for-unsaved-template gap.

None of these endpoints persist — they are dry-run validators. The database is
touched only by create/update on Save / Save & close.

### 4. Server change

`validate` (in `TemplatesController`) broadens its permitted params from
`commands`-only to the full structured set (reusing the existing `template_params`
shape) and returns an added `yaml` key:

```
{ valid: <bool>, errors: [...], yaml: "<rendered cmdscript yaml>" }
```

The `yaml` is produced by rendering a non-persisted `ControlCenter::Template.new(attrs)`
through `TemplateRenderer.to_yaml`. Validation continues to run over
`commands` exactly as today, so behavior for existing callers is unchanged apart
from the additive `yaml` field. Rendering is best-effort over partial/blank input
(`TemplateRenderer` already tolerates blanks), so an incomplete form still yields
a preview.

### 5. YAML code editor (CodeMirror 6)

The YAML pane is a **CodeMirror 6** editor: syntax highlighting, a line-number
gutter, bracket matching, and undo history (all from CM's `basicSetup`), plus
light/dark theming that tracks the app's theme toggle.

**Why CodeMirror over the earlier highlight.js overlay:** highlight.js (and
Prism) are read-only *highlighters*; an editable, line-numbered, theme-aware pane
built on them means hand-rolling a textarea overlay + gutter + a second (light)
token theme. CodeMirror 6 is the popular, official editable editor that provides
all of that natively, so it is both neater and less custom code. The earlier
highlight.js-overlay approach (and its vendored `highlight.js/yaml` grammar) is
removed; highlight.js remains in the app for the vulnerability drawer.

**Supply-chain posture:** CM6 is installed from the official npm registry at
pinned exact versions (`codemirror@6.0.2`, `@codemirror/state@6.7.1`,
`@codemirror/view@6.43.6`, `@codemirror/commands@6.10.4`,
`@codemirror/language@6.12.4`, `@codemirror/lang-yaml@6.1.3`,
`@codemirror/theme-one-dark@6.1.3`), bundled locally into a single self-contained
ESM file with esbuild, and **vendored + committed** at
`web/vendor/javascript/codemirror.min.js` (MIT banner recording versions). It is
pinned in `config/importmap.rb` as `codemirror` and loaded from the app's own
origin — no runtime CDN, matching how `highlight.js` is already vendored.

**Integration:** the Stimulus controller mounts one `EditorView` into a
`yamlEditor` container. `basicSetup + yaml() + keymap.of([indentWithTab]) +
placeholder(...)` plus a theme `Compartment` that holds `oneDark` in dark mode and
the default light theme otherwise; a `MutationObserver` on `<html>`'s class
reconfigures the compartment when the user toggles the theme. The editor's doc is
the YAML source of truth: `_yamlValue()` reads it, `_setYamlValue()` replaces it
inside the `_syncing` guard (so structured→YAML sync and programmatic loads don't
echo through the update listener). An `updateListener` fires the debounced
`validateYaml` on user edits only.

- **YAML comments are not preserved across a structured-side edit.** In Split,
  typing in a structured field regenerates the YAML pane from the model, dropping
  any hand-written comments/formatting there. This is inherent to a
  structured↔YAML mirror; comment-preserving round-trips are out of scope (YAGNI).
- **Server round-trip latency.** Sync is debounced and goes through the server
  rather than converting instantly in the browser. Accepted in exchange for a
  single source of truth for parse/render and no weakening of the YAML security
  boundary.

## Testing

- **Integration test** (`test/integration/api/v1/control_center/templates_test.rb`):
  assert `validate` now returns a `yaml` string for
  valid structured params, and still returns `{ valid:false, errors:[...] }` for
  invalid commands. The `validate_yaml` → `template` path is already covered.
- **JS:** the repo has no Stimulus unit harness, so the split-view sync and save
  buttons are verified manually in the running app (create a template, edit both
  sides in Split, confirm live mirroring, Save keeps it open with `editingId` set,
  Save & close closes, reload confirms mode persisted).

## Files touched

- `web/app/controllers/api/v1/control_center/templates_controller.rb` — enrich
  `validate` (params + `yaml` in response).
- `web/app/views/control_center/templates/index.html.erb` — three-way mode
  toggle, split layout wrapper, two save buttons, "Saved" indicator, CodeMirror
  mount container.
- `web/app/javascript/controllers/control_center_templates_controller.js` — split
  mode, live sync, `lastEdited`, `save({close})` + `editingId` capture,
  localStorage persistence, CodeMirror mount/value/theme wiring.
- `web/config/importmap.rb` — pin `codemirror`.
- `web/vendor/javascript/codemirror.min.js` — vendored CM6 ESM bundle (esbuild,
  pinned versions, MIT banner).
- `web/test/integration/api/v1/control_center/templates_test.rb` —
  `validate` returns `yaml`.

The `validate` route already exists (`config/routes.rb`); no route change needed.
