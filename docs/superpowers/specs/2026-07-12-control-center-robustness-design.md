# Control Center Robustness — Design Spec

> Make the Control Center more robust: raw-YAML template authoring, file upload,
> full cmdscript-schema YAML validation while writing, and a Statistics tab
> (jobs sent, most-used templates, and general job analytics). Security-first,
> neat UI/UX, built to keep changing easily.

**Date:** 2026-07-12
**Status:** Approved for autonomous build (user away, free hands, no questions).
**Prior art:** Control Center web UI (`2026-07-11-control-center-web-ui-design.md`)
and API (`2026-07-10-...`). Statistics pattern: the Vulnerabilities Statistics
tab (`Vulnerabilities::Stats` + `ChartsHelper` + inline-SVG server-rendered views).

## Goals

1. **Raw YAML authoring** — author a template as raw cmdscript YAML in the web UI,
   not only through the structured command-row editor.
2. **File upload** — load a `.yaml`/`.yml` template file into the editor.
3. **Robust YAML validation while writing** — live, server-side validation of YAML
   syntax + the full cmdscript schema + the command allowlist, with clear inline
   errors and a valid/invalid indicator.
4. **Statistics** — a Statistics tab: total jobs sent, success/failure, targets
   dispatched, most-used templates, per-queue and per-day breakdowns.
5. Security throughout; neat, consistent UI/UX; isolated units easy to change.

## Non-goals

- No new gems (Psych/YAML is stdlib; charts are inline SVG per existing pattern).
- Workflow-kind YAML authoring/validation is **out of scope** — the standalone
  sender submits *cmdscript*, so YAML authoring targets the cmdscript schema.
  `kind: workflow` remains a stored value but isn't YAML-validated here.
- No server-side file storage/multipart — files are read client-side into the
  editor (server still caps the resulting `yaml` param as defense in depth).
- No change to the job-submit pipeline: the binary keeps receiving only
  renderer-produced YAML from validated structured fields.

## The cmdscript YAML schema (ground truth)

From `tmp/whiterabbit/pkg/cmdscript/cmdscript.go`, a template YAML is a mapping:

```yaml
name: probe                 # string (required)
tags: [recon]               # list of strings (optional)
desc: probe hosts           # string (optional)  # alias: "description"
output: probe.json          # string (optional)
commands:                   # list (required, >=1)
  - command: httpx          # string (allowlisted)
    args: [-silent, -json]  # list (optional)
    operator: "|"           # "" | "|" | "&&" | "||" (optional)
  - command: nuclei
    args: [-severity, high]
target:                     # mapping (optional)
  type: file                # "file" | "stdin"
  separator: "\n"
  output: targets.txt
```

This is exactly what `TemplateRenderer.to_yaml` already produces and what the
structured columns (`name, kind, tags, description, output, commands, target`)
model. YAML authoring parses this schema into those columns.

## Architecture

**Single source of truth stays the structured columns.** Raw YAML and file upload
are input surfaces: parse (safely) → structured attrs → the existing model
validations (`TemplateValidator`) → persist. Editing an existing template in YAML
mode renders normalized YAML from the structured fields via `TemplateRenderer`.
Submission is unchanged (renderer → validated fields → binary). Consequences:

- The command allowlist / arg-metacharacter checks can never be bypassed by the
  YAML path — they run on the parsed `commands` on every save and every submit.
- The binary never receives raw user YAML bytes.
- No new template column; no submit-pipeline change.

Web → API → services, per module conventions. Two workstreams:

**A. YAML authoring** (new `TemplateYaml` service + templates API/UI changes).
**B. Statistics** (new `JobStats` service + stats API + a server-rendered tab).

## Components

### A1. `ControlCenter::TemplateYaml` (service — the YAML security core)

`ControlCenter::TemplateYaml.parse(str) -> [attrs_or_nil, errors]`

- **Size cap** `MAX_YAML_BYTES = 64_000`, enforced before parsing → error if over.
- **Safe parse**: `YAML.safe_load(str, permitted_classes: [], permitted_symbols: [], aliases: false)`
  inside `rescue Psych::SyntaxError => e` (report `e.message` incl. line/col) and
  `rescue Psych::DisallowedClass / Psych::BadAlias / StandardError` (generic
  "invalid YAML"). This blocks object-injection (`!ruby/object`) and alias bombs
  (billion-laughs) — never `YAML.load`/`unsafe_load`.
- **Root** must be a `Hash` → else "template must be a YAML mapping".
- **Key whitelist** (strict): allowed top-level keys
  `name, kind, tags, desc, description, output, commands, target`. Any other
  key → error listing the offending keys.
- **Field types**: `name` string; `kind` in `%w[cmdscript workflow]` (default
  `cmdscript`); `tags` list→array of strings; `desc`/`description` string (map to
  `description`, `desc` wins if both); `output` string; `commands` list of maps
  each `{command:string, args:list, operator:string}`; `target` optional map
  `{type, separator, output}` strings. Type mismatches → clear per-field errors.
- **Returns** `[{ name:, kind:, tags:, description:, output:, commands: [{command,args,operator}], target: }, []]`
  on success, or `[nil, [errors...]]`. Does **not** run the command allowlist —
  that stays in `TemplateValidator`, invoked by the caller/model so the security
  core has one home.

### A2. Templates API changes (`Api::V1::ControlCenter::TemplatesController`)

- `create`/`update`: if a `yaml` param is present, `TemplateYaml.parse(yaml)` →
  on parse errors render 422 with them; else build/update from the parsed attrs
  (model validations, incl. `TemplateValidator`, still run). Else structured
  params as today.
- New collection action `validate_yaml`: `POST …/templates/validate_yaml` with
  `{ yaml }` → `TemplateYaml.parse` then, if parsed, append
  `TemplateValidator.call(attrs[:commands])` → `{ valid:, errors: [], template: attrs_or_null }`.
  Never persists.
- `serialize`: add `yaml: TemplateRenderer.to_yaml(t)` so the client can populate
  the YAML editor when editing an existing template.
- Routes: `collection { post :validate; post :validate_yaml }`.
- `yaml`/`validate_yaml` size guard: reject `yaml` longer than `MAX_YAML_BYTES`
  with 422 (defense in depth; the client also caps).

### A3. Templates tab UI (`control_center_templates_controller.js` + shell)

- **Editor mode toggle**: `Structured | YAML`. Structured is today's command-row
  editor. YAML mode shows a monospace `<textarea>` prefilled (on edit) from the
  serialized `yaml` field.
- **File upload**: a `<input type="file" accept=".yaml,.yml,text/yaml">`; on pick,
  a `FileReader` reads the text (client-side size cap 64 KB), switches to YAML
  mode, drops the text into the textarea, and validates. No server upload.
- **Live YAML validation**: debounced (300 ms) `POST validate_yaml` → render the
  `errors` list and a valid/invalid badge; Save enabled only when valid.
- **Save**: YAML mode sends `{ yaml }`; structured mode sends structured params.
  On 422, render `detail`.
- Also apply the previously-deferred polish: **debounce the structured
  `validate()`** (shared debounce helper) — closes an earlier follow-up.
- Rows/inputs remain built with `createElement`/`textContent`; errors via
  `textContent`. No client-side YAML parser (no new JS dependency).

### B1. `ControlCenter::JobStats` (service — Postgres aggregates)

`ControlCenter::JobStats.dashboard -> Hash`, computed with AR aggregates over
`ControlCenter::Job`, cached briefly (`Rails.cache`, 60 s TTL, key
`control_center:job_stats:dashboard`). Shape:

```ruby
{
  totals: { jobs:, succeeded:, failed:, pending:, success_rate:, targets:, templates_used: },
  by_status: [ { label:, count:, color: }, ... ],      # for a donut
  top_templates: [ { label: template_name, count: }, ... up to TOP_LIMIT=8 ],
  by_queue:      [ { label: queue_name, count: }, ... ],
  daily:         [ { date: "YYYY-MM-DD", count: }, ... last DAILY_DAYS=30 ],
}
```

- `success_rate` = succeeded / (succeeded+failed) as a rounded %, 0 when none.
- `targets` = `SUM(target_count)`; `templates_used` = `COUNT(DISTINCT template_name)`.
- `daily` buckets by `created_at::date` for the trailing 30 days, zero-filled so
  the chart has a continuous axis.
- Parametrized AR only (`group`, `count`, `sum`, `where`) — no SQL string
  interpolation. Degrades to zeros/empties if a query raises (mirrors the
  vulnerabilities stats' safe-degradation), so the tab never 500s.

### B2. Stats API (`Api::V1::ControlCenter::StatsController`)

`GET /api/v1/control_center/stats` → `render json: JobStats.dashboard`. Module
API parity for external clients. Route: `resource :stats, only: :show, controller: "stats"`.

### B3. Statistics web tab (server-rendered, no JS)

- Add `Statistics` to `ControlCenter::BaseController::TABS` (third tab).
- Route `get "/statistics", to: "statistics#index", as: :statistics`.
- `ControlCenter::StatisticsController#index`: `@stats = JobStats.dashboard`.
- Views under `app/views/control_center/statistics/`: stat tiles (jobs, success
  rate, targets, templates used), a status donut (reuse `ChartsHelper.donut_segments`),
  top-templates bar list, per-queue bar list, and a 30-day daily bar/sparkline,
  each with an empty state. Server-rendered inline SVG — no new JS controller
  (smaller surface, robust). Reuses the health badge partial in the header.
- `ChartsHelper`: add pure geometry helpers as needed (`bar_list_rows` for
  proportional widths; `spark_points`/`bar_series` for the daily chart). Keep
  them data-access-free pure functions like `donut_segments`.

### DB migration

Indexes to keep the aggregates cheap as the jobs table grows:
`add_index :control_center_jobs, :template_name` and
`add_index :control_center_jobs, :status`. No column changes.

## Data flow & auth

Browser → `Api::V1::ControlCenter::*` (session cookie, CSRF via `apiFetch`) →
services → Postgres. Statistics tab is server-rendered (controller → `JobStats`
→ ERB/SVG), no fetch. All endpoints inherit auth from `Api::V1::BaseController`
/ `ApplicationController`. YAML validation and parsing are server-side.

## Security model (explicit)

- **YAML parsing:** stdlib `YAML.safe_load` with `permitted_classes: []`,
  `permitted_symbols: []`, `aliases: false` — blocks Ruby-object instantiation
  and alias/anchor expansion bombs. Size-capped (64 KB) before parse. Root must
  be a mapping; strict top-level key whitelist; per-field type checks.
- **Allowlist is unbypassable:** parsed `commands` always flow through
  `TemplateValidator` (command allowlist + arg metacharacters + caps) on save and
  submit. Raw YAML cannot introduce a non-allowlisted command or shell
  metacharacters.
- **Binary isolation:** the binary receives only `TemplateRenderer`-produced YAML
  from validated structured fields — never raw user bytes.
- **File upload:** client-side read only; no server multipart/disk; server still
  caps the `yaml` param length.
- **Statistics:** read-only, auth-required, parametrized AR aggregates over the
  caller's own data; date buckets computed in Ruby/SQL without interpolation;
  indexed; short-cached; safe-degradation on query error.

## Testing

- `TemplateYaml` unit: valid parse → attrs; non-hash root rejected; unknown keys
  rejected; **unsafe YAML rejected without instantiating** (`!ruby/object:...`
  and an anchor/alias bomb both return errors, no object created); size cap;
  `desc`/`description` mapping; per-field type errors.
- `JobStats` unit: seed jobs → assert totals, success_rate, targets, distinct
  templates, top_templates ordering, by_status, by_queue, daily zero-fill.
- API: `validate_yaml` valid/invalid; `create` via `yaml` persists a valid
  template and 422s a non-allowlisted command supplied through YAML; serialize
  includes `yaml`; `stats` endpoint shape + auth (401 unauthenticated).
- Web: Statistics tab requires auth, renders with the Statistics tab active and
  the tiles/charts/empty-states present; Templates tab renders with the
  mode-toggle + file-input wiring.
- Use `stub_methods`, `sign_in_as(@user)`, `users(:one)`; Mongo not involved.

## Adaptability

- `TemplateYaml` is one isolated unit (parse+schema); the allowlist stays in
  `TemplateValidator`; the renderer is reused — YAML is a thin new input path.
- `JobStats` is one pure aggregate service; the Statistics tab is server-rendered
  and data-driven; adding a panel is a helper + a partial.
- Tabs remain data (`TABS`); the stats API and web tab share one service.
- No new dependencies; every new file has one clear responsibility.

## File inventory (new/changed)

New:
- `web/app/services/control_center/template_yaml.rb`
- `web/app/services/control_center/job_stats.rb`
- `web/app/controllers/api/v1/control_center/stats_controller.rb`
- `web/app/controllers/control_center/statistics_controller.rb`
- `web/app/views/control_center/statistics/index.html.erb` (+ partials as needed)
- `web/db/migrate/*_add_control_center_jobs_stats_indexes.rb`
- Tests: `test/services/control_center/template_yaml_test.rb`,
  `test/services/control_center/job_stats_test.rb`,
  `test/integration/api/v1/control_center/{templates_yaml,stats}_test.rb`,
  extend `test/integration/control_center/tabs_test.rb`.

Changed:
- `web/app/controllers/api/v1/control_center/templates_controller.rb` (yaml
  branch, `validate_yaml`, serialize `yaml`)
- `web/config/routes.rb` (`validate_yaml`, `stats`, web `statistics` tab)
- `web/app/controllers/control_center/base_controller.rb` (add Statistics TAB)
- `web/app/views/control_center/templates/index.html.erb` (mode toggle, YAML
  textarea, file input, valid badge)
- `web/app/javascript/controllers/control_center_templates_controller.js` (YAML
  mode, file read, validate_yaml, debounce)
- `web/app/helpers/charts_helper.rb` (bar-list + daily geometry helpers)
