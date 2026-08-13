# Assistant Chat UI Redesign

**Date:** 2026-08-01
**Status:** Approved
**Module:** Assistant web shell

## Goal

Make the administrator Assistant chat comfortable for sustained use while
keeping it a bottom-right floating panel. The desktop panel will be larger by
default, resizable from its top-left corner, and will remember its last size.
The visual hierarchy will match Hunter's neutral black/zinc application shell,
with cyan used sparingly for primary actions and focus.

## Scope and security boundary

This is a presentation-only change. It does not add an Assistant context type,
tool, provider feature, user role, API, domain write, send action, schedule, or
execution path. Existing capability disclosure, authorization, validation,
auditing, and authoring behavior remain unchanged. No threat-model delta is
required.

The only newly persisted data is the panel's numeric width and height in browser
local storage. It contains no conversation, provider, user, record, or message
data and is never sent to Hunter.

## Chosen approach

Use a small custom resize controller integrated into the existing Assistant
Stimulus controller. A top-left handle suits a panel anchored to the bottom and
right edges: dragging up and left increases the panel, while the bottom-right
corner stays fixed. A focused handle also supports arrow-key resizing.

Panel size calculations and persistence will live in a focused JavaScript
module so clamping, malformed stored values, and mobile behavior can be tested
without a browser driver.

### Alternatives considered

- Native CSS `resize`: smaller implementation, but the browser-provided
  bottom-right handle conflicts with a bottom-right anchored panel and provides
  inconsistent styling and behavior.
- Small/medium/large preset buttons: straightforward and accessible, but does
  not satisfy free resizing and adds controls for an interaction that should be
  direct.

## Window behavior

- Desktop breakpoint: `min-width: 640px`, matching the panel's existing `sm`
  transition.
- Default desktop size: 680 px wide by 780 px high.
- Minimum desktop size: 480 px wide by 520 px high.
- Maximum desktop size: viewport width minus 32 px by viewport height minus
  32 px.
- The bottom and right offsets remain 16 px. Position is not movable or stored.
- The resize handle occupies the panel's top-left corner and has a visible hover
  and focus state without obscuring header controls.
- Pointer dragging applies the clamped size continuously. Releasing or
  cancelling the pointer stores the final size.
- Arrow keys resize by 16 px; Shift+Arrow resizes by 48 px. Left/Up grow the
  anchored panel and Right/Down shrink it. Keyboard changes are stored
  immediately.
- The stored value uses a versioned closed shape under
  `hunter:assistant-panel-size:v1`: `{ "width": number, "height": number }`.
  Missing, malformed, non-finite, or out-of-range values fall back to or clamp
  against the documented bounds.
- On viewport resize, the visible panel is re-clamped. The re-clamped size is
  stored so a window reopened in the same viewport remains visible.
- Below 640 px, the panel remains full-screen, the resize handle is hidden, and
  stored desktop dimensions are neither applied nor overwritten.
- Existing Escape-to-close and mobile focus trapping remain unchanged.

## Visual design and information architecture

### Panel shell

The panel uses white and zinc surfaces in light mode and Hunter's near-black
surfaces in dark mode. Borders, shadows, and translucency establish separation
from the page. Cyan is limited to the launcher, primary actions, active/focus
states, and small status accents. Rose and amber retain their semantic error and
warning meanings.

The desktop panel uses a 12 px corner radius and a restrained shadow. Its larger
default gives the conversation area enough width for code, validation output,
and Control Center drafts.

### Header and disclosure

The header gains a compact Assistant mark, clearer title/status grouping, and a
larger close target. The long capability statement moves into a collapsed
`details` disclosure labelled "Data access & actions". Its complete existing
copy remains server-rendered and available before the first turn, but no longer
permanently consumes chat height.

### Conversation rail

The desktop rail grows from 120 px to 192 px at the default size and uses a
neutral dark treatment that visually connects it to Hunter's sidebar. "New
chat" is the clear primary rail action. Conversation titles truncate cleanly,
the selected conversation receives an active state and `aria-current`, and an
empty state explains when no history exists.

At the minimum width the rail remains 168 px, leaving the conversation column
usable. On mobile it stays narrow enough to preserve the established two-column
flow; changing navigation structure is outside this pass.

### Conversation and composer

- Assistant messages use a quiet bordered surface; user messages use a subtle
  brand-tinted surface instead of inverted black/white bubbles.
- Messages have readable line height, safer long-line wrapping, and a maximum
  width that preserves conversational rhythm while using the larger panel.
- Provider/model metadata and destructive actions move into a compact toolbar.
- Context search moves into a collapsed `details` region labelled "Add Hunter
  context". Selected disclosure previews remain visible and retain all existing
  security behavior.
- The composer becomes a single cohesive surface with a multiline input and a
  compact Send button. Enter submits, Shift+Enter inserts a newline, and the
  input grows up to a bounded height as the user types.
- Status, disabled, polling, validation, draft, and error states keep their
  current behavior and accessible live regions, with colors adjusted for
  legibility in both themes.

## Component boundaries

- `layouts/_assistant.html.erb`: semantic structure, resize handle, disclosure
  sections, and static visual classes.
- `controllers/assistant_controller.js`: pointer lifecycle, keyboard resize,
  viewport listener, composer keyboard/height behavior, and active conversation
  state.
- `lib/assistant_panel_size.js`: defaults, bounds, closed-schema parsing,
  clamping, storage, and anchored resize math.
- `lib/assistant_ui.js`: classes and inert DOM construction for messages,
  contexts, drafts, actions, and the conversation-list empty state.
- `assets/tailwind/application.css`: namespaced resize handle and panel-specific
  styles that are clearer and safer than long dynamic utility strings.

## Failure handling

Local storage is optional. Reads and writes catch browser security/quota errors;
the panel continues with an in-memory default size. Invalid stored data is
ignored. Pointer cancellation ends resizing cleanly. Viewport changes always
clamp the panel to visible bounds.

Assistant API failures, polling behavior, turn cancellation, context limits,
draft validation, and save confirmation remain unchanged.

## Testing

- JavaScript unit tests cover defaults, pointer delta math, min/max clamping,
  versioned storage parsing, invalid data fallback, and storage failures.
- Assistant UI unit tests cover Enter versus Shift+Enter behavior and active or
  empty conversation rendering where extracted helpers are warranted.
- Rails integration tests assert the resize handle, collapsed disclosures,
  accessible labels, live regions, and unchanged capability copy.
- Existing Assistant JavaScript and Rails integration suites must remain green.
- The Tailwind build must complete so every changed class is represented in the
  compiled stylesheet.

## Out of scope

- Moving or docking the panel.
- Persisting panel position.
- Storing any Assistant content in local storage.
- Changing Assistant authorization or capabilities.
- Replacing Rails, Stimulus, importmap, or Tailwind.
- Redesigning the settings page or non-chat Assistant administration.
