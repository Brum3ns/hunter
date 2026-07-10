# Hunter — Vulnerabilities Tab (Vulnerability Management) Design

**Date:** 2026-06-30
**Status:** Approved (design); ready for implementation planning
**Module:** Vulnerability management (the first full web department)

## Goal

Build the web UI for the vulnerability-management module: a single screen that
shows summary stats on top and a searchable, filterable, paginated list of all
findings below. Adapt the reference mockup
(`tmp/design/vulnerabilites_tab_design.png`) to Hunter's monochrome theme, and
structure everything so future sections/columns/filters drop in without
rippling through unrelated code.

## Non-goals

- No create/edit/delete UI in this pass (the JSON API already covers CRUD).
- No Overview-vs-Vulnerabilities split — one screen.
- No live sparkline unless finding documents actually carry dates.
- Not building other modules (programs, CVE, control center).

## Architecture overview

Server-rendered Rails (Hotwire) department. The web controller renders HTML by
calling the module's `Vulnerabilities::MongoSource` service **directly** — it
does not call its own JSON API over HTTP. The existing `/api/v1/vulnerabilities`
JSON API stays as the external/programmatic surface; the web screen and the API
share the same service layer underneath.

```
Browser ──▶ Vulnerabilities::OverviewController#index
                 │
                 ├─▶ Vulnerabilities::MongoSource  (list + search + filters + paging)
                 └─▶ Vulnerabilities::Stats        (Created / Resolved / False Positives)
                        │
                        └─▶ HunterMongo.collection("vulnerabilities")
```

## Web structure (isolation-first)

A reusable `Department` concern carries the per-module web conventions so each
future module's web department is a thin, predictable shell.

- `app/controllers/concerns/department.rb` — included by every module's web base
  controller. Exposes the module's `TABS` to views and provides a small helper
  for the sub-navigation. Keeps cross-module web wiring in one place.
- `app/controllers/vulnerabilities/base_controller.rb`
  (`< ApplicationController`, `include Department`). Declares
  `TABS = [{ name: "Vulnerabilities", path: :vulnerabilities_root_path }]`
  (single tab now; the structure already supports more).
- `app/controllers/vulnerabilities/overview_controller.rb#index` — the screen.
  Reads query params, calls the service + stats, assigns ivars for the view.

### Routing

```ruby
namespace :vulnerabilities do
  get "/", to: "overview#index", as: :root
end
```

Yields `vulnerabilities_root_path` → `/vulnerabilities`.

### Navigation

- Sidebar "Vulnerabilities" entry points at `vulnerabilities_root_path`.
- `NavigationHelper#nav_active?` must also match the first segment of
  `controller_path` (e.g. `vulnerabilities/overview`) so namespaced department
  controllers light up the correct nav item, not just top-level `controller_name`.

## Layout width (opt-in)

The application layout currently hard-codes `max-w-6xl`. Make the container width
opt-in so data-dense departments can go wider without forking the layout:

- `application.html.erb` uses `content_for(:container)` if set, else default
  `mx-auto max-w-6xl px-6 py-10`.
- The vulnerabilities screen sets a wider container (`max-w-screen-2xl`) for the
  table.

## Data flow & params

`OverviewController#index` reads:

- `q` — free-text search.
- `severity` — one of the severity vocabulary values.
- `status` — one of the status vocabulary values.
- `page` — 1-based page (reuse `Api::V1::BaseController`-style clamping logic;
  factor the shared bits so both API and web use the same limits).

It passes these to `MongoSource.list(...)` and renders findings + total count for
pagination. Stats are computed independently of the active filters (they
summarize the whole collection, matching the mockup's top cards).

## Backend changes

### `Vulnerabilities::MongoSource` — add search

Add a `search:` option to the list query. When present, builds an `$or` of
case-insensitive regexes across `finding.name` and `target.host`, AND-combined
with the existing program/severity/status/tool filters.

```ruby
# inside the filter builder
if search.present?
  rx = { "$regex" => Regexp.escape(search), "$options" => "i" }
  filter["$or"] = [{ "finding.name" => rx }, { "target.host" => rx }]
end
```

Reads continue to rescue `Mongo::Error` → empty result.

### `Vulnerabilities::Stats` — new service

`app/services/vulnerabilities/stats.rb`. Computes the three top-card numbers via
`count_documents`, with the status vocabulary held in adjustable constants so the
mapping is easy to tune:

- **Created** — total document count.
- **Resolved** — `report.status ∈ {resolved, closed, fixed}`.
- **False Positives** — `report.status ∈ {false_positive, fp}`.

Returns a small value object/hash: `{ created:, resolved:, false_positives: }`.
On `Mongo::Error`, returns zeros (graceful). Optional: a `sparkline(metric)` that
returns a 30-day series **only if** dated documents exist (real example data
often has `metadata.date == ""`); otherwise the view omits the sparkline.

### JSON API — accept `q`

Add `q` to the permitted filter params in
`Api::V1::VulnerabilitiesController` and forward it as `search:` to the service,
so the API and web search behave identically.

## Views (composable partials)

`app/views/vulnerabilities/overview/index.html.erb` composes small partials so
each piece changes independently:

- `_stat_cards.html.erb` / `_stat_card.html.erb` — the three top cards.
- `_filters.html.erb` — search box + severity + status selects, as a single
  Turbo GET form targeting `vulnerabilities_root_path`.
- `_findings_table.html.erb` / `_finding_row.html.erb` — the list. One row per
  finding.
- `_severity_badge.html.erb` / `_status_badge.html.erb` — reusable cell badges.
- `app/views/shared/_pagination.html.erb` — shared, module-agnostic pager
  (prev/next + page indicator) usable by any future department.

### Columns (one row per finding)

`Severity · Status · Name · Target · Tool · Date`

- **Name** — `finding.name`.
- **Target** — `target.host` (fall back to `target.url`/`target.input`).
- **Tool** — `metadata.tool`.
- **Date** — `metadata.date` (rendered blank when empty).

Column set is defined as a small ordered structure so adding/reordering columns
is a one-place edit, not a table-markup rewrite.

## Monochrome design language

- No color accents. Severity is a **grayscale ramp**, not red/orange:
  Critical = solid black/filled, High = dark, Medium = mid, Low = light,
  Info = faintest. Each badge a small pill consistent with the sidebar's
  black/white active styling.
- Status badges: outlined monochrome pills.
- Cards, table, toolbar follow existing zinc palette; full light + dark mode.
- Mobile-responsive: cards stack; table scrolls horizontally within its container.

## Interactivity (minimal JS)

- One Stimulus controller `filter_form` — auto-submits the filter form on
  `change` (selects) and on debounced `input` (search box). Progressive
  enhancement: the form still works without JS (it's a real GET form).
- Pagination uses plain links (`?page=N` preserving current filters).

## Error handling

- Mongo unreachable / read error → empty findings list with a graceful empty
  state; stats render `0`. No 500s on the web screen (reads are swallowed in the
  service, consistent with module conventions).

## Testing

- **Controller integration** (`test/integration/vulnerabilities/...`): stub
  `MongoSource` and `Stats`; assert the screen renders, filters/search/page params
  are forwarded, empty state renders, nav active-state is correct.
- **Service unit** (`MongoSource`): the new `search:` builds the expected `$or`
  filter and AND-combines with other filters (double the Mongo collection).
- **Service unit** (`Stats`): Created/Resolved/False-Positive counts map to the
  right status vocab (double `count_documents`); zeros on `Mongo::Error`.
- **Helper unit** (`SparklineHelper`): renders inline SVG for a series; returns
  nothing for an empty/dateless series.
- Use the `stub_methods` helper; no live Mongo.

## Extensibility checklist (why it's structured this way)

- New column → add to the ordered column structure + a row partial line.
- New filter → add a param, a select in `_filters`, a clause in the service
  filter builder.
- New tab in this module → add to `TABS`; the `Department` concern renders it.
- New module's web department → copy this shell shape (base controller including
  `Department`, namespaced controllers, module-local partials), reuse shared
  `_pagination` and the opt-in container. Central touch-points stay to a routes
  block + one sidebar entry.
