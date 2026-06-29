# hunter `/api/v1` Vulnerabilities API — Design

Date: 2026-06-29

## Goal

Give hunter two clear "departments" sharing one Rails app: the existing **web UI**
and a new **JSON API** under `/api/v1`. The first API resource is
**vulnerabilities**, read from (and written to) the MongoDB `vulnerabilities`
collection that Raily populates. Full CRUD.

The backend/API conventions deliberately mirror the proven **scope-ui** app
(`Scope::MongoSource`, `Api::BaseController`, `ScopeMongo` initializer), with two
intentional divergences: full CRUD (scope-ui's programs are read-only) and token
auth in addition to session cookies (scope-ui is cookie-only).

## Non-goals (this pass)

- Create/update **validation** — accept any well-formed JSON document for now.
- Free-text search on the list endpoint — defer; filters + pagination only.
- A web UI consuming the API — the `/vulnerabilities` HTML page is unchanged here.
- MongoDB change streams / monitoring (single standalone node; out of scope).

## Document shape

The `vulnerabilities` collection stores documents shaped like `design/bug.json`:

```
id, metadata{program, asset, scan_id, date, tool, description, impact},
report{status}, finding{name, cwe, type, severity, tags[]},
target{input, url, host, ip, port, method},
poc{request, response, confidence, llm_reasoning, curl, extracted[]}
```

Mongo's `_id` (BSON::ObjectId) is mapped to a string `id` on the way out and is
how `show`/`update`/`destroy` address a document.

## Components

### 1. Mongo wiring — `config/initializers/mongo.rb`

A `HunterMongo` `module_function` module copied from scope-ui's `ScopeMongo`:

- Memoized `Mongo::Client.new(addresses, client_options.merge(database:))`.
- Env-driven: `addresses` from `MONGO_HOST` + `MONGO_PORT`; `database` =
  `ENV["MONGO_DATABASE"]` (default `hunter`); `collection_name` =
  `ENV["MONGO_COLLECTION"]` (default `vulnerabilities`). Optional
  `MONGO_USERNAME`/`MONGO_PASSWORD` → `auth_source: "admin"`.
  `server_selection_timeout` / `connect_timeout` = 3.
- `INDEXES` + `ensure_indexes_once!` (mutex-guarded, idempotent) on the fields we
  filter/sort by: `metadata.program`, `finding.severity`, `report.status`,
  `metadata.tool`, `metadata.date`.
- `healthy?` (ping), `reset!` (close + clear memoized client).

Gemfile: add `gem "mongo", "~> 2.21"`.

### 2. Source service — `app/services/vulnerabilities/mongo_source.rb`

`Vulnerabilities::MongoSource` (`module_function`), mirrors `Scope::MongoSource`
but full CRUD against `HunterMongo.collection`:

- `all(filters: {}, page: 1, limit:)` → array of normalized hashes; builds a Mongo
  filter from the allowed keys, applies `skip`/`limit`, sorts by `metadata.date`
  desc. Rescues `Mongo::Error` → `[]`.
- `count(filters: {})` → integer (for pagination metadata). Rescues → `0`.
- `find(id)` → normalized hash or `nil` (invalid ObjectId → `nil`, not an error).
- `create(attrs)` → inserts, returns the new doc's string id.
- `update(id, attrs)` → `$set` the doc, returns updated hash or `nil` if absent.
- `delete(id)` → boolean (deleted_count > 0).
- `normalize(doc)` (private) → stringify keys, map `_id` → string `id`.

Reads never raise to the controller; writes return a result the controller maps
to a status code.

### 3. Model — `app/models/vulnerability.rb`

A PORO wrapping a normalized hash. Readers for the nested sections
(`metadata`, `finding`, `target`, `poc`, `report`) and `id`. `as_json` returns the
serialized envelope. Not persisted in Postgres. Construction:
`Vulnerability.new(hash)`.

### 4. API controllers

**`app/controllers/api/base_controller.rb`** — copied from scope-ui's
`Api::BaseController`:

- `< ActionController::Base` (full forgery stack + the `Authentication` concern).
- `include Authentication`, `wrap_parameters false`, `protect_from_forgery with: :exception`.
- `before_action :force_json` (`request.format = :json`), `before_action :authenticate_api!`.
- Override `request_authentication` → `render json: {error:"unauthorized"}, status: 401`.
- `rescue_from` InvalidAuthenticityToken → 403, ParameterMissing /
  UnpermittedParameters → 400.

**Auth extension (`authenticate_api!`)** — accept either:
- the signed session cookie (existing `resume_session` path, for in-browser calls), or
- `Authorization: Bearer <token>` → look up `ApiToken` by digest, set
  `Current.user`. CSRF protection applies to cookie-authenticated requests only;
  bearer-token requests skip CSRF (no cookie, no forgery risk).

**`app/controllers/api/v1/vulnerabilities_controller.rb`** —
`< Api::BaseController`:

- `index` — filters `program`, `severity`, `status`, `tool` (each optional, mapped
  to the corresponding nested Mongo key) + `page` / `limit`
  (`DEFAULT_LIMIT=50`, `MAX_LIMIT=200`, `clamped_limit`). Returns
  `{ count, page, limit, vulnerabilities: [...] }`.
- `show` — 200 with the doc, or `404 {error:"not_found"}`.
- `create` — inserts the JSON body as-is (no validation this pass), `201` with
  `{ id }`.
- `update` — `$set` from body, `200` with the updated doc, or `404`.
- `destroy` — `204` on success, `404` if absent.
- Private `serialize(vuln)`.

### 5. Token auth — `ApiToken` (Postgres)

New migration + model:

- `api_tokens`: `user_id` (FK), `name`, `token_digest` (unique), `last_used_at`,
  timestamps.
- `belongs_to :user`; class method `authenticate(raw)` → finds by digest, touches
  `last_used_at`, returns the user.
- Token generated by a rake task `api_tokens:create USERNAME=... NAME=...` that
  prints the raw token once (consistent with hunter's CLI-only admin pattern).
  Only the digest is stored.

### 6. Routes — `config/routes.rb`

```ruby
namespace :api do
  namespace :v1 do
    resources :vulnerabilities, only: %i[index show create update destroy]
  end
end
```

## Data flow

```
external client ──Bearer token──┐
                                 ├─> Api::V1::VulnerabilitiesController
browser (session cookie) ───────┘        │
                                         ├─> Vulnerabilities::MongoSource
                                         │        │
                                         │        └─> HunterMongo.collection ─> MongoDB
                                         └─> Vulnerability (PORO) ─> JSON
```

## Error handling

JSON envelopes, consistent status codes:

- `401 {error:"unauthorized"}` — no valid cookie or token.
- `403 {error:"invalid_csrf_token"}` — cookie request missing CSRF token.
- `400 {error:"bad_request", detail:...}` — malformed params / body.
- `404 {error:"not_found"}` — unknown id.
- `500`-class Mongo read failures are swallowed by MongoSource (empty result), so a
  transient Mongo outage yields an empty list, not a crash. Write failures return a
  `502 {error:"upstream_unavailable"}`.

## Testing

No live Mongo in the suite (mirrors scope-ui):

- **Controller integration tests** stub `Vulnerabilities::MongoSource` and assert
  status codes, JSON shape, filter pass-through, pagination clamping, and both auth
  paths (valid cookie, valid bearer token, neither → 401).
- **MongoSource unit test** for `normalize` (id mapping, key stringifying) and the
  filter-building logic, with the `Mongo::Client` doubled.
- **ApiToken model test** for digest auth + `last_used_at` touch.

## Open follow-ups (later passes)

- Create/update validation of the document shape.
- Free-text search across `finding.name` / `metadata.description`.
- Wiring the `/vulnerabilities` HTML page to consume this API.
