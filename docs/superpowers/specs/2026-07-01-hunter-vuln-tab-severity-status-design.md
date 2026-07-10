# Vulnerability tab — severity colors + editable status

**Date:** 2026-07-01
**Module:** vulnerability management (`web/app/.../vulnerabilities`)
**Status:** design approved, pending implementation plan

## Goal

Two changes to the vulnerability tab, keeping the module isolated:

1. Give severity badges in the findings table real colors (the rest of the app
   stays monochrome).
2. Make each vulnerability's status **editable from the table** via an inline
   dropdown, persisted to Mongo, attributed to the acting user.

## Decisions (locked with the user)

- **Status is shared, not per-user.** One status per vulnerability that everyone
  sees. We record *who last changed it* and *when* (attribution), but there is a
  single value — not a per-user view. (Decision "B".)
- **Persistence lives in Mongo**, in the existing `report.status` field, written
  through `Vulnerabilities::MongoSource`. Not a Postgres table. This matches the
  module already owning full Mongo CRUD. Attribution is denormalized into the
  same Mongo doc (Mongo can't FK to a Postgres user).
- **Inline dropdown, applies immediately** — no confirmation step.
- **Severity colors are scoped to the table badges only.** Sidebar, stat cards,
  and status badges stay monochrome. This is a deliberate, contained break from
  the app's monochrome design language.

## 1. Severity colors

Replace the monochrome ramp in `VulnerabilitiesHelper::SEVERITY_CLASSES`
(`web/app/helpers/vulnerabilities_helper.rb`) with a colored map, light + dark
variants:

| severity | light classes | dark classes |
|----------|---------------|--------------|
| info     | `bg-zinc-200 text-zinc-600`   | `dark:bg-zinc-800 dark:text-zinc-400` (unchanged gray) |
| low      | `bg-blue-100 text-blue-700`   | `dark:bg-blue-950 dark:text-blue-300`   |
| medium   | `bg-amber-100 text-amber-800` | `dark:bg-amber-950 dark:text-amber-300` |
| high     | `bg-orange-100 text-orange-700` | `dark:bg-orange-950 dark:text-orange-300` |
| critical | `bg-red-100 text-red-700`     | `dark:bg-red-950 dark:text-red-300`     |

- The `_severity_badge.html.erb` partial is **not** changed — it already consumes
  `severity_badge_classes(...)`.
- `severity_badge_classes` keeps its existing fallback to the `info` entry for
  unknown values.
- **Tailwind purge:** the app uses Tailwind v4 (`@import "tailwindcss"` in
  `app/assets/tailwind/application.css`) with automatic content detection, which
  scans source files including `.rb`. The current zinc classes already live in
  this helper and render, confirming `.rb` is scanned — the new literal color
  classes will be picked up with no safelist needed. Verify after build that the
  colors render (rebuild `app/assets/builds/tailwind.css`).

## 2. Status vocabulary + default

- New constant in `VulnerabilitiesHelper`:
  `STATUSES = %w[new triage reported close false_positive].freeze`
  (replaces the current 6-value `STATUSES`).
- **Display normalization helper** (module-local, e.g. `display_status(raw)`):
  a value in `STATUSES` renders as itself; **anything else — blank, `nil`, or a
  legacy value such as `unreviewed` — renders as `new`.**
- New writes only ever use the new vocabulary, so legacy Mongo values age out
  naturally without a data migration.
- `status_select_options` returns the five statuses as `[humanized, value]`
  pairs (`"False positive"` for `false_positive`, etc.).

## 3. Persistence — `MongoSource.update_status`

Add to `Vulnerabilities::MongoSource`
(`web/app/services/vulnerabilities/mongo_source.rb`):

```ruby
def update_status(id:, status:, user:)
  raise ArgumentError, "invalid status" unless VulnerabilitiesHelper::STATUSES.include?(status.to_s)
  update(id, {
    "report.status"            => status.to_s,
    "report.status_updated_by" => user.username,
    "report.status_updated_at" => Time.now.utc
  })
end
```

- Reuses the existing ObjectId-addressed `update`, which does a `$set`. Using
  dotted nested keys (`report.status`, …) sets those subfields **without
  clobbering** the rest of `report`.
- `update` returns the refreshed normalized doc, or `nil` if the id didn't match.
- On a bad status value → `ArgumentError` (controller maps to **400**).
- On a Mongo write failure → `Mongo::Error` propagates (controller maps to
  **502**, per module convention). Note: `MongoSource.update` currently does not
  rescue, so this already holds.

> The constant is referenced from the helper to keep a single source of truth for
> the vocabulary. If a service→helper reference feels wrong during
> implementation, lift `STATUSES` into a small shared constant the helper and
> service both read — decide at implementation time, but keep one definition.

## 4. Inline dropdown UI + endpoint

- **Route** — a sibling line inside the existing `vulnerabilities` namespace in
  `web/config/routes.rb`:

  ```ruby
  namespace :vulnerabilities do
    get "/", to: "overview#index", as: :root
    patch "/:id/status", to: "statuses#update", as: :status
  end
  ```

- **New controller** `Vulnerabilities::StatusesController#update`
  (`web/app/controllers/vulnerabilities/statuses_controller.rb`, subclassing the module's
  web `BaseController`). Keeps `OverviewController` focused on listing.
  - Calls `MongoSource.update_status(id:, status:, user: Current.user)`.
  - `ArgumentError` → 400; a `nil` return (id not found) → 404.
  - On success, responds with a **Turbo Stream** replacing the row's status cell
    (`turbo_stream.replace` targeting a per-row dom id, e.g.
    `status_cell_<id>`), re-rendering `_status_badge` with the new value.
- **`_status_badge.html.erb`** becomes a small form containing a monochrome
  `<select>` of the five statuses (current value pre-selected), wrapped in a
  `turbo_stream`-returning form that PATCHes the new route. The badge/select
  stays monochrome — colors are severity-only.
- **Stimulus** `status_select_controller.js`
  (`web/app/javascript/controllers/`): on `change`, call
  `this.element.requestSubmit()` so the change applies immediately with no submit
  button. Register in `controllers/index.js` alongside the existing controllers.
- The findings table row (`_finding_row.html.erb`) wraps its status `<td>` in the
  per-row dom id so the Turbo Stream can target it.

## 5. Testing (no live Mongo)

- **Helper test** (`test/helpers/vulnerabilities_helper_test.rb`):
  - `severity_badge_classes` returns the colored class string for each severity
    and falls back to `info` for an unknown value.
  - status normalization: blank / `nil` / `unreviewed` → `new`; each known status
    passes through.
- **MongoSource unit test** (double the collection via the `stub_methods` helper
  in `test/test_helper.rb`):
  - `update_status` issues a `$set` with the three fields and the acting user's
    username + a timestamp.
  - a status not in `STATUSES` raises `ArgumentError` and performs no write.
  - a `Mongo::Error` from the write propagates (not swallowed).
- **Controller integration test** (`test/integration/vulnerabilities/`, stub
  `MongoSource`):
  - PATCH with a valid status → success, renders the Turbo Stream replacing the
    status cell.
  - invalid status → 400.
  - unknown id → 404.
  - unauthenticated → 401.

## Out of scope

- No Postgres table, no per-user status views.
- No colored severity anywhere except the table badges.
- No data migration of legacy `unreviewed` values (handled by display
  normalization).
- No bulk status editing.
