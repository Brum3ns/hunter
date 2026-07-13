# Hunter API Documentation (OpenAPI + Swagger UI) — Design

**Date:** 2026-07-13
**Status:** Approved

## Goal

Give Hunter's multi-module JSON API first-class documentation serving two
audiences with one source of truth:

- **Humans** browse an interactive, module-grouped Swagger UI page reachable
  from the left sidebar, with clear descriptions and try-it-out.
- **LLMs** fetch one machine-readable OpenAPI document
  (`GET /api/v1/openapi`) with a bearer token and learn every endpoint,
  parameter, and response shape without guessing. The document is filtered to
  the token's scopes, so a `cves`-only agent downloads only what it can use.

No new gems. The spec is hand-written per module; Swagger UI is vendored
static assets (same pattern as `web/vendor/simple-icons`). A Minitest drift
test keeps the docs honest.

## Piece 1 — Spec source of truth: per-module YAML fragments

Directory: `web/config/openapi/`

- `base.yaml` — OpenAPI 3.1 skeleton: `openapi`, `info` (title "Hunter API",
  version, a `description` covering auth [session cookie vs
  `Authorization: Bearer`], token scopes, and the error-envelope conventions:
  `401 unauthorized`, `403 invalid_csrf_token`, `403 insufficient_scope`,
  `400 bad_request`, `404 not_found`, `502 upstream_unavailable`),
  `servers` (`/`), `components.securitySchemes.bearerAuth` (http bearer), and
  shared `components.schemas` (`Error`, pagination envelope fields).
- One fragment per module, holding **only** its own `paths` and
  `components.schemas`:
  - `cves.yaml` (index/show/new-feed/config, all filter params incl.
    `min_severity`, list filters, `fields=core`, keyset cursor params,
    saved-filter semantics)
  - `vulnerabilities.yaml` (full CRUD + filters/search)
  - `programs.yaml` (changes, runs)
  - `targets.yaml` (index/show)
  - `control_center.yaml` (templates CRUD + validate/validate_yaml, jobs,
    health, stats)
  - `runner.yaml` (jobs/claim, jobs/:id/result — runner-token auth noted in
    the description)
- Every operation carries: `tags: [<Module Name>]` (drives Swagger UI's
  grouping/sitemap), `summary`, `description`, and the vendor extension
  `x-api-scope: <slug>` naming the token scope it requires (`null`/absent =
  no scope declared, e.g. runner endpoints).
- **Module slug ↔ file name ↔ scope slug are the same string**
  (`cves`, `vulnerabilities`, `programs`, `targets`, `control_center`).
  `runner.yaml` is the one extra fragment without a matching module scope; it
  is included only for wildcard/session requests.
- Adding a module later = dropping in one fragment file. No central edits.

## Piece 2 — `ApiDocs::Spec` service (merge + scope filter)

`web/app/services/api_docs/spec.rb`, a module_function service (mirrors the
MongoSource style):

- `ApiDocs::Spec.document(scopes: nil) -> Hash` — loads `base.yaml`, then
  deep-merges every fragment's `paths` and `components.schemas`.
  - `scopes: nil` or a list containing `"*"` → all fragments.
  - Otherwise → only fragments whose file basename is in `scopes`
    (e.g. `["cves"]` → base + `cves.yaml`).
- Fragment list is discovered by globbing `config/openapi/*.yaml` (base
  excluded), so the service never needs editing for new modules.
- Memoized after first load in production; re-read on every call in
  development (`Rails.env.development?` check) so spec edits show up on
  refresh.
- Duplicate path or schema keys across fragments raise at load time (fail
  loudly in tests rather than silently overwriting).

## Piece 3 — Machine endpoint: `GET /api/v1/openapi.json`

- `Api::V1::OpenapiController < Api::V1::BaseController`, action `show`.
  No `api_scope` declaration — every authenticated caller may read it.
- Renders `ApiDocs::Spec.document(scopes: Current.api_token&.scopes)`:
  bearer tokens get the scope-filtered document; sessions (no api_token) and
  wildcard tokens get everything.
- Route (in the api/v1 namespace): `get "openapi", to: "openapi#show"`.
  Canonical URL is `/api/v1/openapi` (always JSON — the API forces the
  format); the `/api/v1/openapi.json` suffix form also resolves.

## Piece 4 — Human page: `/docs` web department + sidebar link

- Vendor Swagger UI dist files under `web/vendor/swagger-ui/`
  (`swagger-ui.css`, `swagger-ui-bundle.js` — pinned version noted in a
  `VERSION` file). Registered with Propshaft via an asset-path addition, like
  simple-icons.
- `DocsController#index` (plain web controller behind the standard session
  auth) renders a full-width page that boots Swagger UI against
  `/api/v1/openapi.json`, `docExpansion: "list"`, tags sorted by module.
- Route: `get "docs", to: "docs#index"`.
- **Sidebar:** add `{ label: "API Docs", path: docs_path, controllers:
  %w[docs], icon: "code-bracket" }` to `utility_nav_items` in
  `navigation_helper.rb` (renders next to Settings/Help in the existing
  data-driven sidebar; `code-bracket` added to `icon_helper` if absent).
- **Monochrome skin:** a small stylesheet loaded after `swagger-ui.css`
  overriding Swagger UI's greens/blues to Hunter's black-and-white language,
  with `prefers-color-scheme`/theme-toggle dark support and `slim-scroll` on
  its overflow containers.
- **Try-it-out reality:** GET endpoints work with the session cookie; write
  endpoints need a bearer token pasted into the Authorize dialog (bearer
  skips CSRF; cookie POSTs without a CSRF token are rejected). The page
  states this in `info.description` so humans aren't surprised.

## Piece 5 — Anti-drift + validity tests (Minitest, no new gems)

- **Drift test** (`test/services/api_docs/coverage_test.rb`): expands
  `Rails.application.routes` entries under `/api/v1` into
  `[VERB, /api/v1/path-with-{id}]` pairs and diffs them against the merged
  spec's `paths` — **both directions fail**: undocumented route, or
  documented-but-nonexistent route. Normalization: Rails `:id`-style segments
  → `{id}`; format suffixes ignored.
- **Shape test**: merged document parses, `openapi` version present, every
  operation has `summary`, `tags`, and (where the controller declares one)
  `x-api-scope` matching the controller's `required_api_scope`.
- **Service tests**: fragment merge, scope filtering (`["cves"]` includes CVE
  paths only; `["*"]`/nil includes all), duplicate-key raise.
- **Controller tests**: session gets full doc; cves-scoped bearer gets
  filtered doc; unauthenticated gets 401.
- **Docs page test**: `/docs` requires session; renders the Swagger UI mount
  node and vendored asset tags; sidebar shows the API Docs link.

## Piece 6 — Content quality bar

Every operation documents: purpose (one plain-English sentence minimum), all
query/body parameters with types and accepted values (e.g. `min_severity:
critical|high|medium|low`), response envelope schema with an example, error
cases beyond the shared set, and pagination/cursor mechanics. The CVE module
is written to the depth an LLM needs to self-serve end-to-end (scoped token →
`/cves/config` → filtered `/cves/new` polling with `next_since`/
`next_since_id` → `fields=core`).

## Out of scope

- Request/response validation middleware (committee-style) — revisit later.
- Public (unauthenticated) docs.
- Documenting non-API web routes.

## Decisions log

- OpenAPI via hand-written per-module YAML (chosen over rswag — would drag
  RSpec into a Minitest repo — and apipie — controller DSL bloat, dated UI).
- Swagger UI (chosen over Redoc/Scalar for try-it-out + familiarity),
  vendored, monochrome-skinned.
- Spec endpoint is scope-filtered per token; sidebar entry lives in
  `utility_nav_items` next to Help.
