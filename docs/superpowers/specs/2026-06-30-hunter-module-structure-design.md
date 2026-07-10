# Hunter — Strict Per-Module Structure & Generator — Design

Date: 2026-06-30

## Goal

Make Hunter's Rails skeleton organized so that **adding a new section/module is
extremely easy and fully isolated**. Adding a section like "github tracking" must
not require touching another module's code, and must follow one identical shape
across API, service/data, model, and web (tabbed) layers.

Two deliverables:

1. A **strict, uniform per-module convention** covering every layer.
2. A **Rails generator** (`bin/rails g hunter:module`) that scaffolds a complete,
   runnable, isolated section in one command.

The existing **vulnerability-management** module is migrated into this shape as
the proven reference (i.e. "what the generator produces").

## Non-goals (this pass)

- Building out module *features* — this is skeleton preparation only.
- Regenerating the other placeholders (programs / cves / control_center / stats);
  they stay as their current thin stubs.
- Removing orphan pages (`bugs`, etc.) — out of scope this pass.
- Any change to auth, Mongo wiring (`HunterMongo`), or the two shared API base
  controllers' responsibilities — those are already module-ready.

## The convention (every module, no exceptions)

A module has a **name** (`vulnerabilities`, `github`) and a **primary resource**
(`finding`, `repository`). Each module owns exactly these files; nothing outside
them is module-specific:

```
app/services/<module>/mongo_source.rb        # COLLECTION + INDEXES + CRUD
app/models/<resource>.rb                      # flat PORO, distinct name
app/controllers/api/v1/<module>/
  base_controller.rb                          # < Api::V1::BaseController
  <resources>_controller.rb                   # CRUD, < the module API base
app/controllers/<module>/
  base_controller.rb                          # < ApplicationController; TABS + layout
  <tab>_controller.rb                         # one per tab (overview default)
app/views/<module>/
  <tab>/index.html.erb
  _subnav.html.erb                            # in-section tabs, rendered from TABS
test/services/<module>/mongo_source_test.rb   # doubles Mongo collection
test/integration/api/v1/<module>/<resources>_test.rb  # stubs the service
test/models/<resource>_test.rb
```

### Layer details

- **Service** — `<Module>::MongoSource` (module_function), owns `COLLECTION` and
  `INDEXES`, reads swallow `Mongo::Error` to empty results, writes let it raise.
  Mirrors today's `Vulnerabilities::MongoSource`.
- **Model** — a flat PORO wrapping a normalized Mongo doc (e.g. `Vulnerability`).
  Flat (not namespaced) because POROs have distinct names and no clash; matches
  the current `app/models/vulnerability.rb`.
- **API** — module is a Ruby + route namespace under `Api::V1`. Per-module
  `Api::V1::<Module>::BaseController < Api::V1::BaseController` gives each module a
  place for module-local API hooks while inheriting auth/CSRF/JSON/errors +
  pagination from the two shared bases. Resource controller does CRUD.
  URL shape: `/api/v1/<module>/<resources>`.
- **Web department** — module is a controller namespace. `<Module>::BaseController
  < ApplicationController` declares `TABS` (the in-section nav) and sets the shared
  layout. One controller per tab. `_subnav.html.erb` renders from `TABS` so the
  tab list is **module-local** — no shared file enumerates a module's tabs.

### Central registration — only two one-liners

Adding a module edits exactly two shared files, both written by the generator:

1. **Routes** (`config/routes.rb`): a web block and an API block, e.g.
   ```ruby
   namespace :github do
     get "/", to: "overview#index", as: :root
     # one line per additional tab
   end
   namespace :api do
     namespace :v1 do
       namespace :github do
         resources :repositories, only: %i[index show create update destroy]
       end
     end
   end
   ```
2. **Sidebar** (`app/helpers/navigation_helper.rb`): one entry in the modules
   group.

No other shared file changes. Therefore a new module cannot break an existing one.

## The generator

`lib/generators/hunter/module/module_generator.rb` + `templates/*.tt`.

Usage:
```
bin/rails g hunter:module github --resource=repository
```

Behavior:
- Creates every file in the convention from templates, substituting module name,
  resource name, and their inflections.
- Inserts the two registrations (routes via `route`/`inject_into_file`; nav via
  `inject_into_file` into the modules group).
- Generates the three test files.
- Defaults: `--resource` falls back to a singularized module name; a single
  `overview` tab is created (more tabs added by hand or re-running).

Result: a runnable, isolated section with passing placeholder tests, zero edits
to other modules.

## Migrating vulnerabilities (the reference)

Move the existing flat vuln module into the strict shape — this both proves the
convention and becomes the canonical example.

| Before | After |
| --- | --- |
| `app/controllers/api/v1/vulnerabilities_controller.rb` | `app/controllers/api/v1/vulnerabilities/findings_controller.rb` (`Api::V1::Vulnerabilities::FindingsController`) + `api/v1/vulnerabilities/base_controller.rb` |
| route `resources :vulnerabilities` | `namespace :vulnerabilities { resources :findings }` under `api/v1` |
| `app/controllers/vulnerabilities_controller.rb` | `Vulnerabilities::BaseController` + `Vulnerabilities::OverviewController` |
| `app/views/vulnerabilities/index.html.erb` | `app/views/vulnerabilities/overview/index.html.erb` + `_subnav.html.erb` |
| web route `get "vulnerabilities"` | `namespace :vulnerabilities { get "/", to: "overview#index" }` |
| `test/integration/api/v1/vulnerabilities_test.rb` | `test/integration/api/v1/vulnerabilities/findings_test.rb` |

Unchanged: `Vulnerabilities::MongoSource`, the `Vulnerability` PORO and its model
test, `HunterMongo`, the two shared API base controllers.

### Consequence to accept

The public API URL changes:

```
/api/v1/vulnerabilities  ->  /api/v1/vulnerabilities/findings
```

This matches AGENTS.md's stated "rooted at `/api/v1/<module>/…`" convention and
lets the module hold multiple resources later. No external consumers exist yet
(token auth was just added), so this is the cheap moment to make the change.

The sidebar `vulnerabilities_path` becomes the module root path
(`vulnerabilities_root_path` or equivalent); the nav entry's active-state matching
is updated accordingly.

## Error handling

No new error paths. The migrated controllers reuse the existing envelopes from
`Api::BaseController` (`401/403/400/404/502`) and `Api::V1::BaseController`
(`render_not_found`, pagination). Generated controllers inherit the same.

## Testing

- **Generator output**: after migration, the vuln module's existing (relocated)
  tests pass unchanged in behavior — proving the shape works end to end.
- **Per generated module**: service unit test (doubles the Mongo collection via
  the `stub_methods` helper), API integration test (stubs the service, no live
  Mongo), model test. These are the templates the generator emits.
- Full suite (`bin/rails test` from `web/`) must pass after migration.
- A focused test that the generator produces a module whose tests pass is
  desirable but optional this pass (decide in the plan).

## Docs

Update **AGENTS.md** "How to add a module" to: (a) lead with the generator
command, (b) reflect the exact resulting file tree, and (c) reconcile the
`/api/v1/<module>/<resource>` URL shape with reality.
