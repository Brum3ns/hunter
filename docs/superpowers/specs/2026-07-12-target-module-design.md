# Target module — design

**Date:** 2026-07-12
**Status:** In progress — core table, detail panel, and infinite scroll landed;
dork search DSL built but not yet wired (see "Search" below).

## Evolution note (2026-07-12)

The first pass (below) shipped: the module wiring, `Target` PORO, `MongoSource`,
JSON API, web department, and client-side column show/hide/reorder/resize. Since
then the page has grown three capabilities that this spec now folds in:

1. **Search — free text + dork DSL.** A `Targets::SearchParser` +
   `Targets::DorkExpression` pair (mirroring the Vulnerabilities and Programs
   modules) turn the search bar into field-scoped "dorks"
   (`host:*.example.com status:>=500 tech:nginx`) combined with leftover free
   text. **Status: services built, but not yet wired into `MongoSource` or the
   controllers, and not yet tested** — this is the remaining work.
2. **Detail side panel.** Clicking a row opens a docked, click-to-copy detail
   panel over the full `alive` document. **Landed + tested.**
3. **Infinite scroll.** The list pages in on scroll via an `IntersectionObserver`
   sentinel and an HTML rows fragment. **Landed + tested.**

The enriched `Target` model and the sections documenting these follow the
original design below.

## Goal

Add a new **Target** page to Hunter: a left-navbar department listing all "alive"
assets in a rich, column-configurable table. Each row shows an asset's host, IP,
port, detected technologies (as brand icons), HTTP status, title, and more. Users
can show/hide columns, reorder them, and resize their widths. Technology icons
come from a **vendored, trusted, official** icon set (Simple Icons) — no runtime
gem, no supply-chain exposure.

Data shape is `tmp/db_struct/alive.json` (httpx-style probe output):
`metadata`, `target`, `http`, `headers`, `tech[]`, `csp`, `fingerprint`.

## Module wiring (mirrors the Vulnerabilities module)

New `Targets` module reading the `alive` MongoDB collection.

- **`Targets::MongoSource`** (`web/app/services/targets/mongo_source.rb`)
  - `COLLECTION = "alive"`.
  - `INDEXES` on the fields we sort/filter by: `target.host`, `target.ip`,
    `http.status_code`, `metadata.program`, `metadata.date`.
  - `all(filters:, search:, sort:, dir:, page:, limit:)`, `count(filters:, search:)`,
    `find(id)`.
  - Reads swallow `Mongo::Error` (→ empty result / nil), per the house rule.
    Read-only surface — no writes.
  - `build_filter(filters, search)`: free-text search across
    `SEARCH_FIELDS = %w[target.host target.ip http.title tech]` (case-insensitive
    `$regex`), plus exact-match `FILTER_KEYS` (`program`, `status`).
  - Sort: whitelist of sortable Mongo fields keyed by public column name;
    default `metadata.date` desc.
  - `normalize(doc)`: stringify keys, surface BSON `_id` as string `id`.

- **`Target`** PORO (`web/app/models/target.rb`) wrapping a normalized doc.
  Flat accessors: `id, host, url, input, ip, port, scheme, path, verb (target.method),
  status_code, title, webserver, content_type, content_length, words, lines,
  response_time, tech (Array<String>), program, tool, scan_id, failed,
  seen_at (metadata.date), page_type, phash`. Nested-section accessors for the
  detail panel: `metadata, target, http, headers, csp, fingerprint` (each `|| {}`).
  Convenience: `status_family` (2xx/3xx/4xx/5xx/other bucket for the badge color).
  Note `verb`, not `method`, so it never clobbers `Object#method`.

## JSON API

- **`Api::V1::TargetsController` < `Api::V1::BaseController`**
  (`web/app/controllers/api/v1/targets_controller.rb`).
  - `index` — paginated list, honoring `q`, `sort`, `dir`, `page`, `limit`
    (`pagination_page` / `clamped_limit`), plus `program` / `status` filters.
    Returns `{ targets: [...], page:, limit:, total: }`.
  - `show` — one asset by id, or `render_not_found`.
- Routes: a sibling block under `namespace :api { namespace :v1 { ... } }` in
  `web/config/routes.rb`:
  ```ruby
  resources :targets, only: %i[index show]
  ```

## Web department

- **Sidebar entry "Target"** → `/targets`. One-line add in
  `web/app/helpers/navigation_helper.rb` (second/module group), plus a `target`
  heroicon path in `IconHelper::HEROICON_PATHS`. Single page, no sub-tabs (like
  `cves`), so a flat route: `get "targets", to: "targets#index"`.
- **`TargetsController#index`** (`web/app/controllers/targets_controller.rb`)
  calls `Targets::MongoSource` directly (HTML surface shares the service layer
  with the JSON API). Permits `:q, :sort, :dir, :page, program: [], status: []`.
- **Views** (`web/app/views/targets/`):
  - `index.html.erb` — search bar + toolbar + table, with a docked
    `target_panel` Turbo Frame on the right. Full-bleed (`content_for :container,
    "w-full"`) so the dense table reaches the screen edges.
  - `_toolbar.html.erb` — an **Assets `<n>`** count chip + the column-picker
    dropdown. The mockup's `Host/CNAME/IP/Technologies/Title` facet chips and the
    `Start vulnerability scan` / download / refresh actions are **deferred** (see
    Non-goals) — only the total-assets chip and column picker ship this pass.
  - `_table.html.erb` — CSS-grid table shell with header row + column picker;
    carries `data-controller="targets-columns targets-infinite"` and the
    infinite-scroll sentinel.
  - `_row.html.erb` — one asset row; clickable (`rowlink` → `target_panel`).
  - `_rows_page.html.erb` — a bare page of rows + a `data-next-url` marker,
    rendered for XHR infinite-scroll fetches.
  - `_tech_icons.html.erb` — the technology icon cluster (up to 4 + `+n`).
  - `_status_badge.html.erb` — HTTP status pill, colored by family.
  - `show.html.erb` / `_panel.html.erb` / `_field.html.erb` — the detail side
    panel (see "Detail side panel").

### Columns

- **Default-visible** (matches the design): `host, port, ip, technologies,
  status, title`.
- **Toggleable extras**: `url, scheme, path, method, webserver, content_type,
  content_length, words, lines, response_time, program, page_type`.
- **Host cell**: host text + relative "seen" time (e.g. "5mo ago") from
  `metadata.date`, mirroring the design.
- **Status badge**: the one intentional non-monochrome accent —
  2xx green, 3xx blue, 4xx amber, 5xx red — consistent with the design.

### Column show/hide + reorder + resize

CSS-grid-based table (not `<table>`): each row is a grid governed by a shared
`grid-template-columns` custom property. A `targets_columns_controller.js`
Stimulus controller owns all state:

- **Show/hide** — column-picker dropdown (checkboxes) toggles per-column
  visibility.
- **Reorder** — drag a header; the controller sets CSS `order` on that column's
  cells (header + every body cell share a `data-col` key).
- **Resize** — drag a header-edge handle; updates that column's track width in
  the `grid-template-columns` value.
- **Persistence** — `{ order, hidden, widths }` serialized to
  `localStorage["targets.columns"]`, reapplied on connect. No backend, no
  migration, zero central touch-points.

## Technology icons — Simple Icons, vendored

- **Vendored data**: a pinned Simple Icons release extracted (one-time) to a
  single generated file `web/vendor/simple-icons/icons.json`, shape
  `{ "<slug>": { "title": "...", "hex": "RRGGBB", "path": "M..." }, ... }`, plus
  a `web/vendor/simple-icons/VERSION` recording the pinned release. Checked into
  the repo like the CodeMirror vendoring. No runtime gem.
- **`SimpleIcons` service** (`web/app/services/simple_icons.rb`) — loads the
  JSON once into a memoized frozen constant. `lookup(name) → { slug, title, hex,
  path }` or `nil`:
  - Normalize the tech string per Simple Icons slug rules (downcase; map/strip
    accented and special characters; drop non-`[a-z0-9]`).
  - Consult an `ALIASES` table for httpx/Wappalyzer names that don't map cleanly
    (`"ruby on rails" => "rubyonrails"`, `"google analytics" =>
    "googleanalytics"`, `"amazon web services" => "amazonaws"`, …). Table is the
    single extension point for new mismatches.
- **`tech_icon_tag(name, size:)` helper** (in a `TargetsHelper` or shared
  `IconHelper`) — inline `<svg>` filled with the icon's official brand `#hex`
  (same inline-SVG technique as `heroicon`), or a **monogram chip** fallback
  (1–2 uppercase letters in a neutral pill — the "ex"/"N" badges in the design)
  when `lookup` returns `nil`.
- **Cluster**: `_tech_icons` renders up to N icons in a horizontal row with a
  `+M` overflow badge, exactly like the design.

### Sourcing & safety decision (2026-07-12)

The tech comes from Wappalyzer fingerprints (via httpx), so Wappalyzer's own
icon set would match 1:1 — but it was **rejected on supply-chain grounds**:

- The original MIT Wappalyzer repo went commercial; every maintained fork
  (`dochne`, `enthec/webappanalyzer`, `HTTPArchive`) is now **GPL-3.0**. Hunter
  has no license file (proprietary by default), so bundling GPL-3.0 icon assets
  is a copyleft/trademark risk. **Decision: CC0-only Simple Icons; no GPL, no
  Wappalyzer icons, no runtime fetch.**
- Simple Icons is **CC0-1.0 (public domain)**, vendored and pinned. Icons are
  rendered by extracting only `{title, hex, path}` and building the `<svg>`
  ourselves (Rails auto-escaping on the `d`/`hex` attributes) — we never inline
  a raw third-party SVG document, so there is no stored-XSS surface.
- **Coverage** is maximized purely through *matching* (facts, not GPL assets):
  version/noise stripping, `.js`/`.io` de-branding, an `ALIASES` table for
  renames/abbreviations, and a dataset-grounded **title index** (match a tech
  name against each icon's normalized human title, so alternate spellings like
  `NodeJS` resolve). Measured ~**89%** hit rate on a realistic httpx tech corpus.
- The remaining ~11% (Amazon/AWS/CloudFront, Magento, reCAPTCHA — trademark-
  removed from Simple Icons — plus infra like Varnish/HAProxy/IIS/LiteSpeed that
  it never carried) are **genuinely absent from CC0** and correctly fall back to
  the **monogram chip**. That gap is the accepted cost of the CC0-only choice.
- If broader coverage is ever needed, the safe path (not taken) is a hardened
  vendoring of a licensed icon set: pinned commit + checksums, a build-time SVG
  sanitizer that hard-fails on `<script>`/`on*`/`<foreignObject>`/external refs,
  served as `<img>` under CSP `img-src 'self'` — never inlined, never fetched at
  runtime.

## Search — free text + dork DSL

The search bar accepts both plain words and **field-scoped dorks**, mirroring
`Vulnerabilities::SearchParser` / `DorkExpression` (the Target variant is
Mongo-only — there is no in-memory evaluate path to keep in parity). Two small
services under `web/app/services/targets/`:

- **`Targets::SearchParser`** (`search_parser.rb`) — `call(query) -> Result`
  where `Result = Struct(:free_text, :expression)`.
  - Grammar (case-insensitive): `term := KEY ':' [>=|<=|>|<]? (STRING | BAREWORD)`,
    with `AND`/`&&`, `OR`/`||`, and parentheses. AND binds tighter than OR;
    adjacent terms imply AND.
  - **Orphan-operator demotion:** `and`/`or` are operators only when *both*
    neighbors are operands, so "cats or dogs" stays free text.
  - Recognized dork **keys** (`KEYS`, kept in sync with the Mapper): `host url ip
    port method scheme path title webserver content_type tech status program tool
    page_type`. An unrecognized `foo:bar` falls through to free text.
  - `free_text` is the leftover plain words (fed to the broad substring search);
    `expression` is a `DorkExpression` AST (`Term`/`And`/`Or`) or `nil`.

- **`Targets::DorkExpression`** (`dork_expression.rb`) — the AST nodes plus a
  `Mapper` that owns per-key Mongo semantics. Each node answers `#to_mongo`:
  - `Term#to_mongo` → `Mapper.to_mongo(key, op, value)`.
  - `And#to_mongo` / `Or#to_mongo` → `{ "$and"|"$or" => children.map(&:to_mongo).compact }`,
    collapsing a single child to that child and `nil` when empty.
  - **Mapper semantics:**
    - Text keys (`host url ip path scheme title webserver content_type program
      tool page_type tech`) → case-insensitive substring `$regex`; `*` becomes a
      wildcard (anchored `\A…\z`). On the array field `tech`, Mongo matches if
      any element matches.
    - `method`, `port` → exact (anchored `\A…\z`), or wildcard when `*` present.
    - `status` → numeric on `http.status_code`; supports `> >= < <=` (→
      `$gt/$gte/$lt/$lte`), else equality.

- **Wiring (remaining work).** Both controllers call
  `Targets::SearchParser.call(params[:q])`, keep the raw `q` for the search box,
  and hand `MongoSource` the `free_text` as `search:` plus the AST as
  `expression:`. `MongoSource#build_filter(filters, search, expression)` combines
  three clause sources — mapped exact filters, the free-text `$or`, and
  `expression.to_mongo` — under a single top-level `$and` (collapsing to the lone
  clause when only one is present). A top-level `$and` is required because both
  the free-text search and an `OR` dork can each emit a top-level `$or`, and a
  Mongo document can hold only one `$or` key. `count` takes the same
  `expression:` so totals match the filtered list.

## Detail side panel

Clicking a row opens a **docked detail panel** showing the full `alive` document
— no full-page navigation.

- **Row → panel.** Each `_row` is `data-controller="rowlink"` with
  `data-rowlink-url-value=<target_path(id)>` and
  `data-rowlink-frame-value="target_panel"`; a click loads `show` into the
  `target_panel` Turbo Frame docked at the right of `index`.
- **`TargetsController#show`** looks up the asset (`MongoSource.find`), `head
  :not_found` on a miss, and renders `show.html.erb`. A direct visit still
  renders inside the app layout; the frame request swaps just the panel.
- **`side_panel_controller.js`** slides the panel in on connect; on desktop it
  sits in the flex row so the list makes room and stays clickable (click another
  row to swap the panel); on mobile it slides over as a full-width sheet with a
  tap-to-close backdrop. Esc / outside-click close it and empty the frame so the
  same row can reopen it. Clicking another row swaps rather than closes.
- **`_panel`** renders sections mirroring the document — Technologies, Target,
  HTTP, Response Headers, CSP, Fingerprint, Metadata — skipping empty sections so
  short assets stay compact. **`_field`** is a label/value pair that is
  click-to-copy (reuses the shared `copyable` Stimulus controller).

## Infinite scroll

The list pages in on scroll rather than showing pager links.

- `TargetsController#index` computes `@next_page_url` (the same query params with
  `page + 1`) when `@page * limit < @total`, else `nil`. On an XHR request it
  renders only `targets/_rows_page` (rows + a `data-next-url` marker) instead of
  the full page.
- **`targets_infinite_controller.js`** observes a sentinel with an
  `IntersectionObserver` (600px root margin); when it nears the viewport it
  fetches `urlValue`, appends the returned `[data-target-row]` nodes before the
  sentinel, and advances `urlValue` to the fetched fragment's `data-next-url`,
  stopping (and removing the sentinel) when that URL is empty.
- Appended rows inherit the current column widths/visibility because
  `targets_columns_controller` re-applies layout to new body rows.

## Testing
- `Target` model — accessor mapping + `status_family`.
- `SimpleIcons.lookup` — normalization, alias resolution, `nil` on miss.
- `tech_icon_tag` helper — known name → brand-colored `<svg>`; unknown →
  monogram chip.
- `Api::V1::TargetsController` integration — stub the service (no live Mongo);
  index pagination envelope + show / not-found.
- `TargetsController` (web) integration — stub the service; renders the table
  with the default-visible columns, the row → `target_panel` wiring, and the
  infinite-scroll sentinel / XHR rows fragment. *(landed — `index_test.rb`,
  `show_test.rb`)*
- **`Targets::SearchParser` unit** *(remaining)* — free-text-only, single dork,
  dork + free text, implicit AND, explicit OR, orphan-operator demotion
  ("cats or dogs"), range operator, quoted value, unknown key → free text.
- **`Targets::DorkExpression` unit** *(remaining)* — `Term#to_mongo` for a text
  key, a wildcard, an exact key (`method`), and numeric `status` (equality +
  range); `And`/`Or` shapes and single-child collapse; the `tech` array field.
- **`Targets::MongoSource` dork wiring** *(remaining)* — `all`/`count` accept
  `expression:` and combine filter + free-text + dork under `$and`; the existing
  filter-only and search-only cases still hold.

Use the `stub_methods` helper in `web/test/test_helper.rb` (no live Mongo).

## Non-goals (this pass)

- **Toolbar facets and actions** — the mockup's `Host/CNAME/IP/Technologies/Title`
  count chips and the `Start vulnerability scan` / bulk-download / refresh actions
  are deferred; only the total-assets chip and the column picker ship. (Field
  filtering is instead available through the dork DSL, e.g. `host:…`, `status:…`.)
- AI-powered search (the "AI" badge in the design is cosmetic).
- Saved views / per-user server-side column preferences (localStorage only).
- Writing to the `alive` collection (read-only module).

## Design language

Hunter's monochrome black-and-white language holds for chrome, table, and
chips. The two deliberate color exceptions — both present in the reference
design and both information-bearing — are the **HTTP status badges** (by family)
and the **brand-colored technology icons**.
