# Hunter Sitemap web department — design

**Date:** 2026-07-19
**Status:** Approved — ready for implementation plan.

## Goal

Add a **Sitemap** web department: a Burp/Caido-style collapsible tree that shows
each target **origin** as a top-level folder and, on expand, that origin's
crawled endpoints organized as a path-segment tree (folders drill down to leaf
requests). Clicking a leaf shows a minimal endpoint detail panel. This is the
"own web department" follow-on to the sitemap relation + sync
(`2026-07-18-hunter-sitemap-design.md`); it is a **read-only view** over the
existing `sitemap_targets` / `sitemap_endpoints` Postgres tables.

Reference design: `tmp/design/sitemap-left-window-design.png` (the Caido
sitemap). We build the **left window only** (tree + a small detail panel);
the screenshot's request table and raw request/response panes are out of scope.

## Decisions (locked during brainstorming)

- **Top level = target origins, flat.** Each origin (`scheme://host:port`,
  1:1 with a `sitemap_targets` row) is a top-level folder. No apex-wildcard
  grouping (`*.example.com`) in v1.
- **Loading = lazy per-origin.** The index renders only the origin list.
  Expanding an origin fetches and renders that origin's **entire** path tree
  once (folders collapsed); further expand/collapse is client-side only.
- **Scope = tree + minimal detail panel** (method, status, full URL, last-seen).
  No request table, no raw request/response panes.
- **Active endpoints only** (`removed_at IS NULL`); tombstoned endpoints are
  hidden.

## Data (already exists)

- `Sitemap::Target` (`sitemap_targets`): `origin`, `scheme`, `host`, `port`,
  `program`, `removed_at`; `has_many :endpoints`. Scope `.active`.
- `Sitemap::Endpoint` (`sitemap_endpoints`): `target_id`, `origin`, `url`,
  `path`, `method`, `status_code`, `content_type`, `content_length`,
  `last_seen_at`, `removed_at`. Scopes `.active`, `.unmatched`.

No schema changes. Unmatched endpoints (`target_id IS NULL`) are **not** shown
in v1 (the tree is per-origin, and unmatched rows have no origin folder to hang
under — they remain out of scope, consistent with "active endpoints of a
target").

## Components

### 1. `Sitemap::Tree` — path-trie builder (pure service)

`web/app/services/sitemap/tree.rb`. One responsibility: turn a flat list of
endpoints into a nested tree of nodes. No DB, no view concerns — fully unit
testable.

- **Interface:** `Sitemap::Tree.build(endpoints) -> [Node, ...]` (root-level
  nodes). `endpoints` is any enumerable of objects responding to `path`,
  `method`, `status_code`, `id` (i.e. `Sitemap::Endpoint` records).
- **Node** (a `Struct` or plain value object) has:
  - `label` — the path segment for this node (e.g. `"about"`, `"about/"`,
    `"favicon.ico"`).
  - `full_path` — the cumulative path from the origin root (e.g. `"/about/"`).
  - `children` — array of child `Node`s.
  - `endpoint` — the terminating endpoint at this node, or `nil`. Carries
    `id`, `method`, `status_code` (read from the record) for the row + detail.
  - `folder?` — `children.any?`.
  - `endpoint?` — `endpoint` present.
- **Construction rules:**
  - Normalize each path to start with `/`. Split into segments on `/`.
  - A **trailing slash is significant**: `/about` and `/about/` produce
    distinct nodes (`"about"` leaf vs `"about/"` folder) — matches the design.
    Concretely: keep the trailing empty segment produced by a trailing `/` and
    fold it into the parent segment's label as `"<seg>/"`, marking that node a
    directory.
  - Intermediate segments create folder nodes even if no endpoint terminates
    there (an implied directory).
  - A node may be **both** a folder and an endpoint (a request terminates at it
    *and* it has descendants) — e.g. `/api` requested with `/api/users` present.
    Rendered as an expandable row that is also selectable.
  - The path `/` (root request) attaches its endpoint to a synthetic root leaf
    labeled `"/"`.
  - **Sort:** within each node, folders first then leaf endpoints, each group
    ascending by `label` (case-insensitive).
  - **Dedup:** multiple endpoints with the same `path` but different `method`
    collapse to one node; the node keeps a representative endpoint (lowest
    `id`) for the detail link. (Method-level breakout is a non-goal.)

Exact segment edge cases (empty path, `//`, query already stripped in `path`)
are pinned by the builder's unit tests.

### 2. Routes + controllers

Mirrors the CVE/Target departments. `Sitemap::BaseController <
ApplicationController` includes the existing `Department` concern and declares
`TABS = [{ name: "Sitemap", path: :sitemap_root_path }]`.

```ruby
namespace :sitemap do
  get "/",                 to: "origins#index",   as: :root
  get "/origins/:id/tree", to: "origins#tree",    as: :origin_tree   # :id = sitemap_targets.id
  get "/endpoints/:id",    to: "endpoints#show",   as: :endpoint      # :id = sitemap_endpoints.id
end
```

- **`Sitemap::OriginsController#index`** — lists `Sitemap::Target.active`
  ordered by `host, port`, each with its active-endpoint count. Honors a
  `?q=` **domain search** that filters origins by `host ILIKE %q%`. Renders the
  page shell (origin list + empty detail pane).
  - Endpoint counts: one grouped query
    (`Sitemap::Endpoint.active.where(target_id: ids).group(:target_id).count`)
    to avoid N+1.
- **`Sitemap::OriginsController#tree`** — loads one `Sitemap::Target` (active),
  builds nodes with `Sitemap::Tree.build(target.endpoints.active)`, renders the
  tree fragment (a Turbo Frame). `head :not_found` on a missing/removed target.
- **`Sitemap::EndpointsController#show`** — loads one active
  `Sitemap::Endpoint`, renders the detail panel fragment (method, status badge,
  full `url` click-to-copy, `last_seen_at`). `head :not_found` on a miss.

### 3. Views

`web/app/views/sitemap/`:
- `origins/index.html.erb` — full-bleed two-column layout: left column has the
  **"Search domain…"** input (submits `q` to `#index`) + the origin list; right
  column is the detail Turbo Frame (`sitemap_detail`) with an empty state. Uses
  `content_for :container, "w-full"` like the Targets page.
- `origins/_origin.html.erb` — one origin folder row (host + `:port`, lock/globe
  glyph by scheme, count badge). It wraps a lazily-loaded Turbo Frame
  (`id="origin_tree_<id>"`, `src` set to `origin_tree_path` on first expand) so
  the tree loads on demand.
- `origins/tree.html.erb` — the per-origin tree fragment: the Turbo Frame body
  rendering the root nodes, or an empty state when the origin has no active
  endpoints.
- `origins/_node.html.erb` — **recursive** partial for one tree node: chevron +
  folder icon for folders, file icon for leaves; the label; and, for endpoint
  nodes, a click target (handled by `sitemap_tree_controller`, see below) that
  loads `sitemap_endpoint_path(endpoint_id)` into the `sitemap_detail` frame.
  Renders its `children` by re-rendering `_node` inside a collapsible `<ul>`.
- `endpoints/show.html.erb` — the detail panel: method, an **inline** status
  pill colored by family (2xx/3xx/4xx/5xx), the full `url`, and relative
  last-seen. The status pill is a few lines of ERB local to this department — it
  does **not** depend on the (uncommitted) Targets `_status_badge` partial, so
  the Sitemap department is self-contained.

### 4. Stimulus

- **`sitemap_tree_controller.js`** — one self-contained controller owning all
  interactivity so the department has no dependency on the uncommitted Targets
  JS:
  - **Folder toggle:** folder rows show/hide their child `<ul>` (client-side)
    and rotate the chevron.
  - **Lazy origin load:** an origin row's first expand sets the wrapped Turbo
    Frame's `src` (`origin_tree_path`); later toggles just show/hide.
  - **Endpoint selection:** clicking an endpoint node loads
    `sitemap_endpoint_path(id)` into the `sitemap_detail` Turbo Frame (by
    setting the frame `src`) and applies a selected style to the row.
  State is ephemeral (no persistence in v1).

### 5. Sidebar + icon

- Add `{ label: "Sitemap", path: sitemap_root_path, controllers: %w[sitemap],
  icon: "sitemap" }` to `primary_nav_groups` in `navigation_helper.rb` (after
  "Target").
- Add a `sitemap` heroicon path to `IconHelper::HEROICON_PATHS` (a tree/rectangle
  glyph, e.g. Heroicons `rectangle-group`).

## Design language

Hunter's monochrome chrome. The two information-bearing color accents already in
the codebase apply: the **HTTP status badge** (by family) in the detail panel,
and otherwise neutral tree rows. Tree rows stay clean — icon + label only — so
the tree reads like the reference design; method/status live in the detail panel.

## Error handling

- Missing/removed target on `#tree` → `head :not_found` (the frame shows a
  not-found state).
- Missing/removed endpoint on `#show` → `head :not_found`.
- Origin with zero active endpoints → the tree frame renders an explicit
  "No endpoints" empty state.
- No Mongo involvement — this department reads Postgres only.

## Testing

- **`Sitemap::Tree` unit** (`test/services/sitemap/tree_test.rb`): single-level
  leaves; nested folders; folder-and-endpoint node; trailing-slash distinction
  (`/about` vs `/about/`); implied intermediate directories; root `/` request;
  sort order (folders before files, alphabetical); same-path/different-method
  dedup.
- **`Sitemap::OriginsController` integration**
  (`test/integration/sitemap/origins_test.rb`): index lists only active origins
  ordered by host with correct counts; `?q=` filters by host; `#tree` renders
  the nested nodes for a target and the empty state for one with no endpoints;
  removed/missing target → 404.
- **`Sitemap::EndpointsController` integration**
  (`test/integration/sitemap/endpoints_test.rb`): renders method/status/url/
  last-seen for an active endpoint; removed/missing → 404.
- **Sidebar**: extend the existing sidebar/nav test to assert the Sitemap entry
  renders and is active on `/sitemap`.

Postgres-backed tests use fixtures or inline record creation (no Mongo, no
service doubling needed — the tables are real).

## Module placement

`Sitemap` web controllers under `web/app/controllers/sitemap/`, views under
`web/app/views/sitemap/`, the `Sitemap::Tree` service under
`web/app/services/sitemap/` (alongside the existing sync services), the Stimulus
controller under `web/app/javascript/controllers/`, routes in
`web/config/routes.rb`, sidebar in `navigation_helper.rb`, icon in
`icon_helper.rb`. Reuses only the committed `Department` concern and the shared
app layout/Turbo setup; all tree interactivity lives in the new
`sitemap_tree_controller.js`, and the status pill is local ERB — so the
department does not depend on the uncommitted Targets module.
