# Hunter Programs module — port of the Scope web UI program page

**Date:** 2026-07-09
**Status:** Approved (design)
**Scope of this pass:** The **program catalog page** of the Scope web UI, ported
into Hunter as a self-contained **Programs** module. Config, logs, and monitor
are explicitly out of scope.

## 1. Goal

Scope-ui has a rich program-catalog page (dork search, faceted sidebar, card +
table views, program detail modal, per-user favorites/trash/history). Hunter's
Programs tab is currently a one-line stub. This work ports the full program-page
feature set into Hunter as an **isolated module** that mirrors Hunter's existing
vulnerability-management "department" conventions, re-skinned from Scope's custom
Tailwind theme to Hunter's monochrome zinc design language.

Two guiding constraints from the user:
- **Feature parity** with Scope's program page — every feature the Scope web UI
  program page has.
- **Isolation** — the module must not blend into Hunter's general code; it lives
  under its own `Programs::` namespace (controllers, services, views, JS), the
  same way `Vulnerabilities::` does.

Scope's service layer and Hunter's vulnerability-management service layer are
already near-identical in shape (both have `Query`, `Filter`, `Sort`,
`SearchParser`, `DorkExpression`, a `MongoSource`, and a `Department` base
controller). So this is a **structural port + re-skin**, reusing most of Scope's
Ruby and JS verbatim, not a rewrite.

## 2. Module shape (isolation)

Everything under a `Programs::` namespace, mirroring `Vulnerabilities::`.

### Controllers (`app/controllers/programs/`)
- `Programs::BaseController < ApplicationController` — `include Department`;
  declares `TABS = [{ name: "Programs", path: :programs_root_path }]`.
- `Programs::OverviewController < Programs::BaseController` — `index` (the
  catalog list; renders the bare cards/rows partial for XHR infinite-scroll
  requests) and `modal` (returns the program detail modal as a standalone
  fragment). Ported from Scope's flat `ProgramsController`, namespaced to fit
  Hunter's department pattern.
- `Programs::FavoritesController`, `Programs::TrashesController`,
  `Programs::ViewsController` — JSON toggle/track endpoints, ported.

The current one-line `ProgramsController` stub is removed.

### Services (`app/services/programs/`)
Ported near-verbatim from Scope (same `Programs::` namespace keeps internal
cross-references working):
- `MongoSource` — **new**, mirrors `Vulnerabilities::MongoSource`. Owns the
  `programs` collection + its `INDEXES`. Reads swallow `Mongo::Error`.
- `Source` — read side (`all`, `find`, `changes_since`, `latest_update`), reads
  through `MongoSource`.
- `Query` — Mongo faceted search/sort/pagination with in-memory fallback;
  returns the `Result` struct (programs, total, platforms, scope_types,
  bounty_ceiling, page, per_page, has_next).
- `Filter` — in-memory filter pipeline (fallback path).
- `Sort` — sort-key registry + direction resolution.
- `SearchParser` — dork grammar → `free_text` + `DorkExpression` AST.
- `DorkExpression` — `Term`/`And`/`Or` nodes + `Mapper` (per-key `to_mongo` and
  `evaluate`, kept side by side).
- `ScopeType` — canonical asset-type taxonomy + raw-token expansion.

Only change to ported service code: swap Scope's single-collection `ScopeMongo`
wiring for Hunter's collection-agnostic `HunterMongo` (see §3).

### Models
- `Program` (`app/models/program.rb`) — PORO wrapping a normalized Mongo doc.
  Ported as-is **except** platform color/logo constants (see §4).
- New Postgres models `Favorite`, `Trash`, `ProgramView` (see §5).

### Views (`app/views/programs/`)
Index + partials, re-skinned (see §4): `index`, `_sidebar`, `_card`,
`_card_items`, `_row`, `_row_items`, `_cards`, `_skeleton_card`, `_modal`,
`_active_chips`, `_sort_control`, `_history`, `_filter_range`,
`_filter_dual_range`.

### JS (`app/javascript/controllers/`)
Program-page Stimulus controllers, ported (see §6). Hunter auto-registers any
`*_controller.js` via `eagerLoadControllersFrom` + `pin_all_from` — no importmap
or index.js edits needed.

## 3. Data source & Mongo wiring

`Programs::MongoSource` (module, mirrors `Vulnerabilities::MongoSource`):
- `COLLECTION = "programs"`.
- `INDEXES` covering the fields Query filters/sorts by: `platform`,
  `scope.type`, `bounty_max`, `report_count`, `updated_at`, and a unique `_sid`.
- Reads go through `HunterMongo.collection("programs")`; index creation through
  `HunterMongo.ensure_indexes_once!("programs", INDEXES)`; health via
  `HunterMongo.healthy?`.

Every `ScopeMongo.collection` / `ScopeMongo.healthy?` /
`ScopeMongo.ensure_indexes_once!` reference in the ported `Query`/`Source` is
replaced with the `HunterMongo` equivalent. Read failures fall back to the
in-memory `Filter`+`Sort` path (already present in Scope's `Query`).

Programs are the source-of-truth in Mongo (upserted by the Scope Go CLI in
production). For dev/test:
- **Seeds:** `db/seeds.rb` gains a guarded block that upserts a handful of
  sample programs (adapted from Scope's `tests/assets/program*.json`) into the
  `programs` collection when it is empty.
- **Tests:** Mongo is doubled per Hunter convention (`stub_methods`); no live
  Mongo required.

## 4. Re-skin to Hunter's design language

Scope uses a custom Tailwind theme (`bg`, `surface`, `edge`, `brand`, `text`,
`text-soft`, `text-dim`, `gold`, `pf-*` platform colors). Hunter is monochrome
zinc. Every ported view is re-skinned:

| Scope token | Hunter replacement |
|---|---|
| `bg-bg` / `bg-surface` | `bg-white dark:bg-[#111315]` |
| `border-edge` | `border-zinc-200 dark:border-zinc-800` |
| `text-text` / `text-text-soft` / `text-text-dim` | `text-zinc-900 dark:text-zinc-100` / `-600 dark:-400` / `-500 dark:-400` |
| `text-brand` / `bg-brand` accent | Hunter's monochrome active treatment (zinc-900 / white pills) — **no color accent** |
| `text-gold` favorite star | monochrome: filled zinc when active, outline when not |
| `pf-hackerone` etc. platform colors, banners, bundled logo images | **dropped** — platform shown as a neutral zinc badge/text; no colored logos, no bundled image assets |

- **Icons:** replace Scope's `icon "..."` helper calls with Hunter's `heroicon`.
  Extend `IconHelper::HEROICON_PATHS` with the new glyphs the page needs (search,
  star, grid, list, arrow-up, arrow-down, funnel, trash, clock, x-circle) as
  inline SVG paths. No icon gem — consistent with the project's official/popular-
  gems-only policy.
- **Platform detail** (`Program::PLATFORM_COLORS`, `PLATFORM_LOGOS`,
  `#colors`, `#platform_logo`): removed from the model; the model keeps only the
  data accessors and `bounty_range`/currency logic.
- Typography, card radii, sticky search bar, and the collapsible-filter pattern
  follow Hunter's existing vuln-overview conventions.

## 5. User-state (Postgres)

Three tables, each `user_id` + `program_sid` with a unique composite index:
- `favorites` — the ★ favorites filter and favorites sort.
- `trashes` — hide/trash filter.
- `program_views` — recent-views history dropdown (`viewed_at` bumped on open).

Models `Favorite`, `Trash`, `ProgramView` (ported), plus `User` gains:
`has_many :favorites/:trashes/:program_views`, and helpers `favorite_sids`,
`trash_sids`, `recent_views(limit:)`. The three JSON controllers (ported) toggle
/ track by `program_sid`. `recent_views` resolves each stored sid back to a live
`Program` via `Programs::Source.find`, skipping any that have since disappeared
from Mongo.

## 6. Stimulus controllers

Ported logic verbatim, re-skinned only:
`auto_submit`, `auto_open`, `column_sort`, `dual_range`, `range`,
`favorite_toggle`, `trash_toggle`, `grid_cols`, `infinite_scroll`, `modal`,
`modal_nav`, `view_mode`, `view_tracker`, `scroll_top`, `sidebar`, `sort_dir`,
`asset_export`, `clipboard`.

**One deliberate substitution:** Scope's `purified_html` controller sanitizes
program-policy HTML in the modal client-side via DOMPurify (an external JS
dependency). Instead, the policy HTML is sanitized **server-side** with Rails'
built-in `sanitize` helper when rendering the modal, and the controller is
dropped. This avoids adding an external JS dependency and keeps the importmap
clean.

**Dropped along with platform images:** `banner_fallback`, `logo_fallback`,
`image_loaded` (no platform banner/logo images in the monochrome skin).

## 7. Routes

```ruby
namespace :programs do
  get "/",            to: "overview#index",  as: :root
  get "/:sid/modal",  to: "overview#modal",  as: :modal
  resources :favorites, only: %i[create destroy]
  resources :trashes,   only: %i[create destroy]
  resources :views,     only: %i[create]
end
```

Replaces the current `get "programs", to: "programs#index"`. The sidebar nav
entry in `navigation_helper.rb` updates `programs_path` → `programs_root_path`.

## 8. Testing

Following Hunter conventions (doubled Mongo, `stub_methods`; Postgres `hunter_test`
reachable):
- **Service unit tests** (double the Mongo collection): `Query`, `Filter`,
  `Sort`, `SearchParser`, `DorkExpression`, `ScopeType`. Scope ships no program
  service tests, so these are written fresh against Hunter's conventions.
- **Controller integration** (stub the services, no live Mongo):
  `Programs::OverviewController` HTML render + the XHR bare-partial path;
  `Favorites`/`Trashes`/`Views` JSON endpoints.
- **Model tests:** `Program` PORO (bounty_range/currency edge cases) and the
  three Postgres models (uniqueness scoping, User helpers).

## 9. Explicitly out of scope (this pass)

- Scope's **config, logs, monitor** pages.
- The `/api/v1/programs` **JSON API** surface. Scope has one and Hunter's module
  convention calls for a per-module API, but this pass is scoped to the *web UI*
  program page; the API is added later mirroring the vuln API.
- Program **change-diff / snapshots** (a monitor feature: `ProgramChange`,
  `ProgramSnapshot`, `ProgramDiffer`).
- Platform **logo images** (dropped for the monochrome skin).

## 10. Reuse summary

- **Verbatim (namespace + Mongo-wiring swap only):** `Query`, `Filter`, `Sort`,
  `SearchParser`, `DorkExpression`, `ScopeType`, `Source`.
- **Verbatim minus platform color/logo constants:** `Program` model.
- **Verbatim (Postgres):** `Favorite`, `Trash`, `ProgramView` models + the three
  toggle controllers + `User` helpers.
- **Ported + re-skinned:** all views, all listed Stimulus controllers.
- **New:** `Programs::MongoSource`, `Programs::BaseController`, seeds, tests,
  extended `IconHelper` glyphs, routes.
- **Dropped:** `purified_html` (→ server-side sanitize), image-fallback
  controllers, platform colors/logos, JSON API, monitor/diff features.
