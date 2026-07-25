# Control Center Template Workspace and Dork Search — Design Spec

**Date:** 2026-07-23
**Status:** Implemented
**Module:** Control Center templates

## Problem

The Templates page renders its editor after the template table and only reveals
it after **New template** or **Edit**. With a large Whiterabbit template library,
opening a row requires a small action target and then a long scroll to reach the
editor. The list also has no search, so locating one template among many is slow.

## Goals

- Turn the Templates tab into a desktop workspace with an editor that remains at
  the top and a separately scrolling template list beneath it.
- Start with a blank, editable creation form when no persisted template is
  selected.
- Open a template by clicking anywhere on its table row, while preserving the
  existing explicit actions.
- Prevent silent loss of unsaved editor changes when changing the active record
  or resetting the form.
- Add instant free-text and dork-expression search consistent with Hunter's
  other search pages.
- Preserve bulk YAML import, structured/YAML/split editing, validation, job
  dispatch, and all current API contracts.

## Non-goals

- No API filtering, pagination, database migration, route, or dependency change.
- No virtualized table, saved searches, query history, facets, sorting changes,
  or user-specific editor state beyond the existing persisted editor mode.
- No redesign of the template schema, validation rules, YAML rendering, or bulk
  import conflict behavior.
- No desktop side-by-side editor layout. The approved arrangement is editor
  above list.

## Workspace layout

### Desktop

Below the existing page header and Control Center tabs, the Templates section is
a viewport-bounded vertical workspace. It has two independently scrolling
regions:

1. A top editor pane with a bounded share of the available height. Its toolbar
   remains at the pane's top and its structured, YAML, or split content scrolls
   inside the pane.
2. A bottom library pane that consumes the remaining height. Its search/toolbar
   and table header remain visible while table rows scroll.

The split must preserve a usable list even when the structured editor is long.
Desktop sizing should target roughly half the available workspace for each pane,
with practical minimum heights rather than fixed pixel-only dimensions. The page
itself should not require scrolling merely to move between editor and library.

### Small screens

Nested fixed-height panes are removed on small screens. The editor remains above
the library, but both participate in normal vertical page flow. Controls and
table content retain the existing responsive wrapping and horizontal overflow
behavior.

## Editor states and transitions

### Blank creation state

The editor is rendered and mounted on initial page load. When no persisted
template is active, it contains blank editable fields, the default
`cmdscript` kind, no target, and one empty command row. Save actions remain
disabled until the existing validation rules are satisfied.

**New template**, **Cancel**, **Save & close**, and successful deletion of the
selected template return to this blank creation state. The editor never becomes
hidden.

### Persisted selection

Clicking a template row loads that record into the editor and marks the row as
selected. The selection is represented by the template ID, not its table
position, so filtering or refreshing cannot accidentally select a different
record. The selected styling remains visible whenever that row is part of the
filtered result.

The existing **Edit** button invokes the same selection path and remains for
discoverability. **Send** and **Delete** stop row activation and perform only
their named action. Opening the send flow does not clear or hide the editor.

Rows expose hover and selected states and are keyboard reachable. Enter or Space
on a focused row opens it. Native buttons within a row retain their own keyboard
behavior and do not bubble into row selection.

### Saving and resetting

- **Save** persists the form and leaves the returned template selected.
- **Save & close** persists the form and then resets to blank creation state.
- **Cancel** discards the current editor contents and resets to blank creation
  state; it no longer hides the editor.
- **New template** resets to blank creation state.

After a successful create, **Save** adopts the returned ID, so later saves update
the same template and its table row becomes selected.

## Unsaved-change protection

The controller tracks whether the current editor has user-authored changes since
the last clean state. A clean state is established after initial blank setup,
after loading a template, after a successful save, and after an intentional
reset.

User changes in structured fields, command rows, target controls, or CodeMirror
mark the editor dirty. Programmatic structured/YAML synchronization, validation
responses, template loading, and form reset do not. Editor mode changes alone do
not mark the record dirty.

Before a dirty editor is replaced by a different row, **Edit**, **New template**,
or **Cancel**, Hunter shows one native confirmation asking whether to discard the
unsaved changes. Declining keeps the existing editor and selected row unchanged.
Selecting the already-active row is a no-op and does not prompt. Search,
refresh, completed bulk import, and opening **Send** never replace editor content
and therefore do not prompt.

Delete retains its existing explicit deletion confirmation. If the deleted
record is selected, a successful deletion resets the editor to a clean blank
state. Deleting another record leaves the active editor untouched.

## Search experience

The library toolbar gains a search field above the table. It filters the
controller's last successfully fetched template collection as the user types;
it does not submit a form or call the API. Input is debounced by 100 milliseconds
to avoid redundant work without introducing a perceptible delay.

The toolbar includes:

- placeholder examples for plain text and dorks;
- Hunter's question-mark syntax-help popover;
- a result count formatted as `N of M templates`;
- a clear action shown when the query is non-empty; and
- a query-specific empty state: `No templates match this search.`

The ordinary empty-library message remains distinct: `No templates yet. Create
one to get started.` Search never resets or mutates the editor. If the selected
template is filtered out, it remains loaded but its row is simply absent until
the query changes.

## Query language

Search is case-insensitive. Adjacent terms imply `AND`; explicit `AND` binds
tighter than `OR`; parentheses override precedence. Quoted values may contain
spaces, and `*` is a wildcard. These forms are valid:

```text
nuclei
name:nuclei-* tag:cve
kind:cmdscript AND (tag:cve OR tag:network)
command:"httpx -silent"
creator:alice
```

### Dork keys

| Key | Data searched | Matching |
| --- | --- | --- |
| `name:` | Template name | substring, or glob when `*` is present |
| `kind:` | Template kind | exact, or glob when `*` is present |
| `tag:` | Any tag | exact, or glob when `*` is present |
| `command:` | Executable names and flattened arguments | substring, or glob when `*` is present |
| `creator:` | `created_by` | exact, or glob when `*` is present |

A plain-text term matches template name, description, tags, executable names,
and command arguments. Multiple plain-text terms follow the same boolean grammar
as dork terms.

An unknown `key:value` token is treated as literal plain text rather than as an
always-false filter. An incomplete quote, unmatched parenthesis, misplaced
operator, or otherwise malformed expression falls back to a safe best-effort
plain-text search. Query input can never throw from the Stimulus event handler or
leave the table in a broken state.

Wildcard matching is implemented by escaping the user's text before translating
`*` into a match-anything expression. Query text is never evaluated as raw
regular-expression syntax or inserted as HTML.

## Architecture

### Pure template search module

Add a DOM-independent ES module under `web/app/javascript/lib/`. Its public
surface accepts a query and plain serialized template objects:

```javascript
parseTemplateQuery(query)
filterTemplates(templates, query)
```

The parser returns a small `Term`/`And`/`Or` expression tree. The evaluator owns
all field mapping and matching semantics. Keeping both operations pure allows
Node tests to exercise precedence, malformed input, wildcard escaping, and
template matching without Stimulus, Rails, or a browser DOM.

### Stimulus controller

The existing `control-center-templates` controller remains the page coordinator.
It gains:

- `templates`, containing the last successfully fetched full collection;
- `query` and a filtered render path;
- `editingId` as the persisted selection key;
- a dirty flag and one guarded-reset/switch path;
- search input, count, clear, list-error, and empty-state targets; and
- row selection, keyboard activation, and selected-state rendering.

`refresh()` only replaces `templates` after a successful, well-formed API
response. It then reruns the active query. A failed refresh preserves the prior
collection and visible results, and displays a concise inline list error.

The current editor-population routines remain responsible for setting fields and
CodeMirror. They run inside the existing synchronization guard and explicitly
establish a clean state only after population completes. All record-replacing
actions route through the same discard-confirmation helper so row clicks and the
Edit button cannot drift behaviorally.

### Editor session state

Add a second small DOM-independent module for `editingId` and clean/dirty
transitions. It exposes operations to mark the session dirty or clean and to ask
whether replacing the active record requires confirmation. The Stimulus
controller still owns the browser confirmation and all form population; the
helper only makes the state machine explicit and independently testable.

### Rails API

No endpoint changes are required. `GET /api/v1/control_center/templates` already
returns every searchable field: `id`, `name`, `kind`, `tags`, `description`,
`commands`, `created_by`, and rendered `yaml`. Filtering remains client-side and
continues to use the current authenticated index request.

## Data flow

1. On connect, mount CodeMirror and establish clean blank creation state.
2. Fetch the template index; on success, cache the full collection and render it
   through the active query.
3. On search input, parse/evaluate against the cache and rerender only the table,
   result count, and appropriate empty state.
4. On row activation, run the unsaved-change guard. If accepted, populate the
   editor, set `editingId`, establish clean state, and rerender selection styling.
5. On user editor input, mark the session dirty and run existing validation/sync.
6. On successful save, use the API response to establish the selected ID and
   clean state, then refresh the cached list without clearing the editor.
7. On completed bulk import, refresh and reapply the query while preserving the
   editor session.

## Failure handling

- Initial index failure shows a dedicated unavailable-list error instead of
  claiming that the library is empty; the blank editor remains usable.
- Later refresh failures retain the last good collection and filtered rows.
- Search parse/evaluation failures fall back safely and do not alter editor
  state.
- Save and validation failures retain the current editor and dirty state, using
  the existing inline errors.
- A selected template absent after a successful refresh remains loaded whether
  clean or dirty; Hunter never silently discards the editor. A later save uses
  the existing API error path if that record was deleted elsewhere.

## Accessibility and safety

- Search has a visible or screen-reader-accessible label and a native search
  input.
- Result counts and list errors use polite live regions.
- The search-help popover follows the established Hunter hover/focus pattern.
- Rows expose keyboard focus and `aria-selected`; action buttons remain native
  buttons with independent activation.
- Focus moves into the editor's name field after an accepted row switch or blank
  reset.
- All template and query-derived content continues to use `textContent`, never
  `innerHTML`.

## Testing

### Pure JavaScript tests

Use Node's built-in `node:test` and `node:assert/strict`, with no dependency
changes. Cover:

- plain-text matching across every supported field;
- each supported dork and its exact/substring semantics;
- case insensitivity, quotes, and escaped wildcard matching;
- implicit AND, explicit AND, OR precedence, and parentheses;
- unknown dorks as literal text;
- malformed expressions falling back without throwing;
- result ordering matching API ordering; and
- filtering without mutating the source array.

Cover editor-session clean/dirty state, same-record no-ops, accepted and declined
switches, save, and reset transitions in a focused Node test for the pure session
helper.

### Rails integration markup

Extend the dedicated Templates-page integration coverage rather than the shared
Control Center tabs test. Assert the authenticated page renders:

- the desktop workspace/pane structure;
- a permanently visible editor with blank-state affordances;
- search input, help, count, clear, list-error, and empty-state targets;
- independent-scroll and responsive-fallback classes; and
- row-selection actions/targets that can be asserted statically.

### Regression and browser verification

Run the focused search tests, template import tests, focused Rails integration
tests, existing Control Center tests, and the full Rails suite. In a browser,
verify:

- desktop pane sizing and independent scrolling at short and tall viewport
  heights;
- mobile normal-flow fallback;
- row click, keyboard activation, selected styling, and action-button isolation;
- accepted and declined unsaved-change prompts from structured and YAML modes;
- Save, Save & close, Cancel, New template, delete, refresh, and import state
  transitions;
- search help, query grammar, count, clear, both empty states, and selection
  persistence while filtered out; and
- light and dark themes.

## Concurrent-work boundary

Another contributor is adding an unrelated Control Center tab. This work must
not alter routes, `ControlCenter::BaseController::TABS`, or the shared
`web/test/integration/control_center/tabs_test.rb`. Recheck the shared worktree
before every edit and preserve unrelated changes, including the contributor's
Control Center Ansible files and documentation.

Expected implementation scope:

- `web/app/views/control_center/templates/index.html.erb`
- `web/app/javascript/controllers/control_center_templates_controller.js`
- `web/app/javascript/lib/template_search.js` (new)
- `web/app/javascript/lib/template_editor_session.js` (new)
- `web/test/javascript/template_search_test.mjs` (new)
- `web/test/javascript/template_editor_session_test.mjs` (new)
- a dedicated Templates workspace integration test (new or existing dedicated
  file)
