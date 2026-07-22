# Hunter Sitemap — tree redesign + filters — design

**Date:** 2026-07-19
**Status:** Approved — ready for implementation plan.

## Goal

Improve the existing Sitemap web department
(`2026-07-19-hunter-sitemap-web-department-design.md`) in two ways:

1. **Tree redesign** — replace the flat `pl-4` indentation and emoji icons with a
   modern **elbow-connector** tree (├─ / └─) that visually conveys depth, using
   **SVG icons** throughout. Annotate leaves: show a **method chip for non-GET**
   endpoints, and render **parameterized endpoints (URL with a query string) in
   red**.
2. **Filters** — a robust filter panel over the origin list and each origin's
   tree: method, minimum endpoint count (default hides 0-endpoint origins),
   status family, path-contains, has-parameter/query, content-type, program,
   and scheme.

Read-only view over `sitemap_targets` / `sitemap_endpoints`. **No schema
changes** — every filter maps to an existing column.

## Available columns

- `sitemap_endpoints`: `method`, `status_code`, `content_type`, `path`, `url`
  (full URL incl. query), `target_id`, `removed_at`, `last_seen_at`.
- `sitemap_targets`: `host`, `port`, `scheme`, `program`, `removed_at`.

"Has a parameter/query" is derived: the endpoint's `url` contains `?`.

## Part A — Tree redesign

### A1. `Sitemap::Tree::Node` — two new derived attributes

The builder still keys nodes by path segment and dedups same-path endpoints to a
representative (lowest id). It additionally **aggregates across all endpoints
that map to a node**:

- `methods -> Array<String>` — the sorted, unique, upcased HTTP methods of every
  endpoint at that node (e.g. `["GET", "POST"]`).
- `has_query? -> Boolean` — true if **any** endpoint at that node has a `url`
  containing `?`.

`Node` becomes `Struct(:label, :full_path, :endpoint, :children, :methods,
:has_query)` with `folder?`, `endpoint?`, `has_query?` predicates. `methods`
defaults to `[]` for pure folder nodes with no terminating endpoint.

Implementation: while inserting an endpoint at its terminal node, push its
`method.upcase` into the node's method set and OR its `url.include?("?")` into
`has_query`. Non-terminal (folder) nodes accrue nothing unless an endpoint also
terminates there.

### A2. Elbow-connector tree (pure CSS)

No per-row connector markup — connectors are drawn with CSS so arbitrary depth
works:

- Each nested `<ul>` (a folder's children container) carries a class that draws a
  **vertical guide** via `border-left` (a 1px line in a subtle zinc/`white/10`
  tone), offset so it sits in the indent gutter.
- Each row's `<li>` draws a **horizontal elbow stub** via a `::before`
  pseudo-element (a short horizontal rule from the guide to the row).
- The **last child** in each `<ul>` truncates its vertical guide at the elbow
  (the `└` corner) using `li:last-child::after` masking the guide below the
  elbow, so the line stops at the last item.
- The top-level origin list has **no** guide/elbow (origins are roots).

This is standard CSS-only tree styling; exact Tailwind utility classes / a small
scoped CSS block are an implementation detail, but the structure above is fixed.
Rows keep their `data-node` / `[data-children]` / `data-action` wiring unchanged
so `sitemap_tree_controller.js` still works.

### A3. SVG icons (no emojis)

All emojis (`🔒 🌐 📁 📄 ▸`) are removed. Icons come from `IconHelper` heroicons
(add any missing paths to `HEROICON_PATHS`):

- **Toggle chevron:** `chevron-right`, rotated 90° when open (replaces `▸`).
- **Folder:** `folder` (closed) / `folder-open` (open) — the controller may swap
  these on toggle, or a single `folder` icon is acceptable if swapping adds
  complexity; the chevron already signals open/closed.
- **Leaf:** `document`.
- **Origin scheme:** `lock-closed` for https, `globe-alt` for http.

Icons render at a small size (`h-4 w-4`) in a neutral tone, inheriting the
existing `heroicon` helper.

### A4. Leaf annotations

- **Method chip:** for a leaf/endpoint node, render a small uppercase chip for
  **each non-GET method** in `node.methods` (GET is omitted as the common
  default; a GET-only node shows no chip). Chips are subtly colored by method,
  e.g. POST amber, PUT/PATCH sky, DELETE red, other zinc — monochrome-friendly
  pills consistent with the app's language.
- **Parameterized (red):** when `node.has_query?`, the node label renders in a
  red text tone (`text-red-600 dark:text-red-400`) to flag it. This applies to
  both leaf and folder+endpoint nodes.

## Part B — Filters

### B1. `Sitemap::EndpointFilter` — shared endpoint scope

`web/app/services/sitemap/endpoint_filter.rb`. Turns a permitted params hash into
a single `ActiveRecord::Relation` over `Sitemap::Endpoint.active`, so `#index`
counts and `#tree` building apply identical endpoint criteria.

- **Interface:** `Sitemap::EndpointFilter.apply(scope, params) -> relation`
  where `scope` is a `Sitemap::Endpoint` relation (caller passes `.active` or a
  target-scoped relation) and `params` is a hash (permitted controller params).
- **Endpoint-level filters:**
  - `methods` (array) → `where(method: methods)` (upcased) when present.
  - `status` (array of families `"2","3","4","5"`) → `status_code` in the union
    of the corresponding ranges (200–299, …). Endpoints with a null status_code
    are excluded when a status filter is active.
  - `path` (string) → `where("path ILIKE ?", "%#{sanitize_sql_like(path)}%")`.
  - `has_query` (truthy) → `where("url LIKE ?", "%?%")` (literal `?` escaped via
    `sanitize_sql_like`).
  - `content_type` (string) → `where("content_type ILIKE ?",
    "%#{sanitize_sql_like(content_type)}%")`.
- Unknown/blank params are ignored. Filters compose (AND).

Target-level filters (`program`, `scheme`, host `q`) are **not** in
`EndpointFilter`; they apply to the `Sitemap::Target` scope in `#index`.

### B2. `Sitemap::OriginsController#index`

- **Target scope:** `Sitemap::Target.active.order(:host, :port)`, plus:
  - host `q` → `host ILIKE` (existing).
  - `program` → `where(program:)` when present.
  - `scheme` → `where(scheme:)` when present (`"http"`/`"https"`).
- **Filtered counts:** `EndpointFilter.apply(Sitemap::Endpoint.active, params)
  .where(target_id: candidate_ids).group(:target_id).count`.
- **Min count + visibility:** `@min_count = [params[:min_count].to_i, 1].max`
  (default 1). Keep only targets whose filtered count `>= @min_count`. So an
  origin with 0 matching endpoints is hidden by default.
- Assigns for the filter panel: `@methods`, `@status`, `@path`, `@has_query`,
  `@content_type`, `@program`, `@scheme`, `@min_count`, plus `@programs` (the
  distinct list of `sitemap_targets.program` for the program dropdown) and
  `@method_options` (distinct methods present, for the method chips).

### B3. `Sitemap::OriginsController#tree`

- Load the active target (404 as before).
- `endpoints = Sitemap::EndpointFilter.apply(@target.endpoints.active, params)`.
- `@nodes = Sitemap::Tree.build(endpoints)`.
- Empty state when no endpoints match the filters.

### B4. Threading filters into the lazy tree

The `_origin` partial builds each frame's `data-src` as
`sitemap_origin_tree_path(target, <endpoint-filter params>)` — i.e. the current
`methods/status/path/has_query/content_type` params are carried so the lazily
loaded tree matches the filtered counts. A small helper
(`sitemap_endpoint_filter_params`) centralizes which params to forward (endpoint
filters only — not `program`/`scheme`/`q`/`min_count`, which are origin-level).

### B5. Filter panel UI

A compact, collapsible **Filters** disclosure at the top of the left column,
below the existing "Search domain…" box. It is a single GET `<form>` targeting
`sitemap_root_path` so submitting reloads the origin list with the params; the
frames then inherit them via `data-src`.

Controls: method (multi chips/checkboxes from `@method_options`), status family
(2xx/3xx/4xx/5xx checkboxes), min endpoint count (number, default 1), has
parameter (checkbox), path contains (text), content-type (text), program
(select from `@programs`), scheme (select: any/https/http). An "Apply" submit and
a "Clear" link (back to `sitemap_root_path`). The panel stays monochrome; the
only color accents are the status pill (detail) and the red parameterized label.

## Error handling

- `#tree` on a missing/removed target → `head :not_found` (unchanged).
- Empty results (no origins after filtering, or no endpoints in a tree) → explicit
  empty states.
- Blank/garbage filter values are ignored (no error), so a bad query never 500s.

## Testing

- **`Sitemap::Tree`** — new: `methods` aggregation (GET+POST at one path →
  `["GET","POST"]`), `has_query?` true when any variant has `?` and false
  otherwise, defaults (`methods == []`, `has_query? == false`) on pure folders.
  Existing 8 tests still pass.
- **`Sitemap::EndpointFilter`** — each filter in isolation (methods, status
  family incl. null-status exclusion, path ILIKE, has_query, content_type) and a
  combination; blank params → unfiltered.
- **`Sitemap::OriginsController#index`** — filtered counts reflect method/status
  filters; `min_count` default hides 0-endpoint origins and a raised `min_count`
  hides low-count ones; `program`/`scheme` filter the origin list; `@programs`
  populated.
- **`Sitemap::OriginsController#tree`** — the tree is built from the filtered
  endpoint set (e.g. a method filter drops non-matching leaves); empty state when
  filters exclude everything; the response still 404s on a bad target.
- **Views** — `_node` renders SVG icons (no emoji bytes present), a non-GET
  method chip only for non-GET nodes, the red label class when `has_query?`, and
  the elbow tree container classes; `_origin` frame `data-src` includes the
  active endpoint-filter params; the filter panel renders the controls with
  current values echoed.

Postgres-backed tests (no Mongo, no service doubling). Reuse `sign_in_as`.

## Module placement

- New service: `web/app/services/sitemap/endpoint_filter.rb`.
- Modified: `web/app/services/sitemap/tree.rb` (aggregate `methods`/`has_query`),
  `web/app/controllers/sitemap/origins_controller.rb` (filters), the sitemap
  views (`origins/index`, `_origin`, `tree`, `_node`), a new `_filters` partial,
  the tree CSS (a small scoped stylesheet or Tailwind utilities), and
  `icon_helper.rb` (add any missing heroicon paths — note this file is already
  uncommitted from the department work; icon additions join that uncommitted
  set). `sitemap_tree_controller.js` gains only an optional folder-icon swap; its
  existing behavior is unchanged.
- Stays self-contained: no dependency on the uncommitted Targets module.

## Design language

Monochrome chrome and tree. Deliberate color accents, all information-bearing:
the **red parameterized-endpoint label**, the **method chips** (subtle per-method
tone), and the existing **status pill** in the detail panel. Everything else —
guides, elbows, icons, folder rows — stays neutral zinc.
