# Control Center: target (file/stdin) handling in the structured editor

**Date:** 2026-07-12
**Status:** Approved (design)
**Module:** Control Center (web department)

## Problem

Whiterabbit `*-tf-*` ("target-file") templates carry a `target:` block that tells
the worker how to deliver the incoming target list to the command:

```yaml
target:
  type: "file"          # "file" | "stdin"
  separator: "\n"       # how targets are joined
  output: "/tmp/targets-__UUID__.txt"  # path the client writes the list to
```

The command then references `__TARGET_FILE__` (file type) or `__TARGET_STDIN__`
(stdin type). Hunter's backend already parses (`TemplateYaml`), validates
(`TemplateYaml#target_field`), renders (`TemplateRenderer`), permits
(`TemplatesController#template_params` → `target: [:type,:separator,:output]`),
and persists (`control_center_templates.target` jsonb) this block. But the
**structured editor has no fields for it** — so a `*-tf-*` template can only be
authored by hand-editing the YAML pane. This adds the missing structured UI.

## Goals

- Author the `target` block from the structured form: pick a type, a separator,
  and an output path — no hand-written YAML required.
- Flow it through the existing save, live structured↔YAML sync, and populate-from-
  YAML paths already built for the editor.
- Preserve today's behavior when no target is configured (block omitted).

## Also in scope: download the template YAML

A **Download .yaml** button sits next to the existing **Upload .yaml** control.
Clicking it downloads the editor's current YAML (`_yamlValue()`) as a file named
from the template — `<name>.yaml` (slugified; falling back to `template.yaml`
when name is blank) — via a client-side `Blob` + object URL (no server round-trip).
This is the natural inverse of Upload and reuses the value the editor already
holds; it is included here because it touches the same view/controller region.

## Non-goals

- Any server/schema change — the backend already supports `target` end to end.
- Modelling Whiterabbit workflow (`kind: workflow`) target semantics.
- Per-target vs compressed execution logic (that lives in Whiterabbit).

## Whiterabbit contract (verified against `pkg/cmdscript/cmdscript.go`)

`Target{ Type, Separator, Output }`, where `Type` is `"file"` or `"stdin"`,
`Separator` joins targets (e.g. `"\n"`), and `Output` is the local path the client
writes the decompressed target list to. The block is optional — many templates
omit it. All 17 `*-tf-*` example templates use `type: "file"`, `separator: "\n"`,
`output: "/tmp/targets-__UUID__.txt"`.

## Design

### UI — a "Target" section in the structured panel

Rendered below Commands, three controls:

1. **Type** — `<select>`: **None** (default), **File**, **Stdin**.
   - `None` → no `target` key is sent; the renderer omits the block (its existing
     "omit when blank" behavior), preserving today's output for non-target
     templates.
   - `File` → command reads `__TARGET_FILE__`; `Stdin` → `__TARGET_STDIN__`.
2. **Separator** — `<select>` of common values mapped to *real* characters:
   **Newline** (`\n`, default), **Comma**, **Space**, **Tab**, **Custom…**
   (reveals a text input). Storing the real character is what makes it serialize
   as `separator: "\n"` (verified: a newline value renders double-quoted and
   round-trips), matching the templates and sidestepping backslash-escape
   ambiguity in a raw text field.
3. **Output file** — text input, path the target list is written to, e.g.
   `/tmp/targets-__UUID__.txt` (used by File type; harmless for Stdin).

A one-line helper notes: File type → use `__TARGET_FILE__` in args; Stdin →
`__TARGET_STDIN__`.

The controls are hidden/shown by Type: when Type is None, separator/output are
irrelevant and can be disabled or hidden.

### Data flow (controller JS)

Symmetric with the existing structured fields:

- `collectTarget()` → returns `{ type, separator, output }` when Type is File or
  Stdin, or `null`/omitted when None. Separator resolves the dropdown selection
  (or the custom text) to its real-character value.
- The result is added to the **save** payload (`_save`) and the **validate**
  (structured→YAML preview) payload (`validate`) under a `target` key, only when
  present.
- `_populateStructured(attrs)` sets the three controls from `attrs.target` (mapping
  a real-character separator back to the matching dropdown option, else Custom),
  so the live split-sync mirrors the target block too.
- `newTemplate()` resets Type to None; `openEditor(t)` populates from `t.target`.
- Editing a target control triggers the existing `validateDebounced` so the YAML
  preview updates live.

No new server endpoint or param — `template_params` already permits
`target: [:type, :separator, :output]`, and `validate` builds a `Template.new(attrs)`
that renders the target through `TemplateRenderer`.

### Rendering / omission

`TemplateRenderer#to_hash` already does `hash["target"] = template.target if
template.target.present?`. To keep None templates unchanged, the JS omits the
`target` key entirely when Type is None (so `Template.new` gets no target and the
block is omitted). An all-blank target hash must never be sent.

## Error handling

Unchanged. `TemplateYaml#target_field` already rejects a non-mapping target,
unknown keys, or non-string values with clear errors; those surface in the YAML
pane on parse and on save. `TemplateValidator` covers commands only (target needs
no allowlisting — it is not executed as a command).

## Testing

- **Renderer unit test** — a template with a File target round-trips: `type`,
  `separator` (newline preserved), and `output` present in the rendered YAML and
  re-parse to the same values; a template with no target omits the block.
- **JS** — no unit harness; verified manually: in the structured form, set
  Type=File, Separator=Newline, Output=`/tmp/targets-__UUID__.txt`, reference
  `__TARGET_FILE__` in a command, and confirm (a) the Split YAML pane mirrors the
  `target:` block matching a `*-tf-*` template, (b) save persists it, (c) reopen
  repopulates the controls, (d) switching Type to None drops the block.

## Files touched

- `web/app/views/control_center/templates/index.html.erb` — Target section
  (type/separator/output controls + helper) in the structured panel; a
  **Download .yaml** button next to Upload.
- `web/app/javascript/controllers/control_center_templates_controller.js` —
  target targets, `collectTarget()`, separator mapping, payloads, populate,
  new/open init, change-to-validate wiring; a `downloadYaml()` action.
- `web/test/services/control_center/template_renderer_test.rb` — target
  round-trip / omission tests.
