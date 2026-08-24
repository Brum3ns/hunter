# Hunter — Agent Context

> Project-local context for any AI assistant (Claude, Codex, Cursor, …). This is
> the source of truth that travels with the repo. Keep it current.

## What Hunter is

**Hunter is a full bug-bounty dashboard** — a web app + JSON API for running an
entire bug-bounty workflow end to end.

**The project goal / pivot (since 2026-06-30):** Hunter began as a narrow
*vulnerability-management* app, but that scope has been **deliberately retired**.
Vulnerability management is now just **one module** of a larger, multi-module
bug-bounty dashboard (programs, vuln management, control center, CVE tracking).
Treat "full bug-bounty dashboard" as the project's purpose — not vuln management.

The user's own intent note: **`llm/rails_app_layout.md`** (light, authoritative).
Design specs + implementation plans: **`docs/superpowers/`** (`specs/`, `plans/`).

## Module architecture (the target shape)

Hunter is composed of **separate modules**. Each module has its **own API
endpoint** rooted at `/api/v1/<module>/...` and its **own web "department"**
(a distinct section of the UI). Modules are kept separated in the code.

1. **Programs** — bug-bounty programs. Being ported from the older **scope-ui**
   app (see `tmp/scope/`), which already has a programs Mongo collection + API.
2. **Vulnerability management** — track vulnerabilities. *Already exists*:
   `Vulnerabilities::MongoSource` + `/api/v1/vulnerabilities` (full CRUD).
3. **Control center** — create/run jobs and templates, driven by the CLI tool
   **Whiterabbit**.
4. **CVE tracking** — track CVEs.

> **Current effort is preparation, not building.** The goal right now is to make
> the Rails app *ready* to drop these modules in easily and consistently — shared
> base classes, multi-collection Mongo wiring, per-module routing, and a
> per-module web layout. Do **not** build out the modules unless asked.

## Tech stack & layout

- Ruby 3.3.6, **Rails 8**, Tailwind CSS v4, importmap-rails + Stimulus/Turbo
  (Hotwire), Propshaft, Minitest. Ruby module namespace is `Hunter`.
- The Rails app lives in **`web/`**; the repo root (this file's dir) is its parent
  and holds `docker-compose*.yaml`, `Dockerfile`, `llm/`, `docs/`, `design/`,
  `json_struct/`, and `tmp/scope/` (the scope-ui reference checkout).

## Data stores

- **PostgreSQL** — users, sessions, API tokens, config. Rails 8 built-in
  username+password auth; the current user is `Current.user` (resolved from a
  session cookie **or** a bearer token).
- **MongoDB** — finding/program/CVE data. **Each module reads/writes its own
  collection.** Wiring is `HunterMongo` (`web/config/initializers/mongo.rb`):
  collection-agnostic — callers name the collection and pass its index spec via
  `HunterMongo.ensure_indexes_once!(name, indexes)` / `HunterMongo.collection(name)`.
  Env: `MONGO_HOST/PORT/DATABASE/USERNAME/PASSWORD` (wired in docker-compose).

## API conventions

- All JSON lives under `/api/v1/...`, grouped by module in `web/config/routes.rb`.
- `Api::BaseController` (`< ActionController::Base`) holds auth + CSRF + JSON +
  error handling. Auth accepts **either** the signed session cookie (browser,
  CSRF-protected) **or** `Authorization: Bearer <token>` (external clients, CSRF
  skipped — no cookie, no forgery risk).
- `Api::V1::BaseController` (`< Api::BaseController`) holds cross-module helpers:
  `pagination_page`, `clamped_limit`, `render_not_found`. **Every module API
  controller should subclass this.**
- Tokens: `ApiToken` (Postgres, SHA-256 digest only). Mint with the rake task
  `bin/rails api_tokens:create USERNAME=<u> NAME=<label> SCOPES=cves,programs`
  (raw token shown once). Tokens carry `scopes` (module slugs or `*`); a
  controller declares `api_scope :<module>` and bearer requests lacking that
  scope get `403 insufficient_scope`. Cookie/session requests are unaffected.
- CVE tokens carry a saved `cve_filter` (set via `api_tokens:set_cve_filter
  USERNAME=<u> NAME=<label> FILTER='{...}'`); `GET /api/v1/cves` and
  `/api/v1/cves/new` apply it as defaults, request params override per field,
  `?fields=core` returns the compact LLM serialization, and
  `GET /api/v1/cves/config` echoes the token's filter.
- Error envelopes: `401 unauthorized`, `403 invalid_csrf_token`,
  `403 insufficient_scope`, `400 bad_request`, `404 not_found`,
  `502 upstream_unavailable` (Mongo write failure). Mongo *read* failures are
  swallowed to an empty result.

## How to add a module (the pattern)

Mirror the vulnerability-management module:
1. **Service** — `app/services/<module>/...` (e.g. a `MongoSource` with its own
   `COLLECTION` + `INDEXES`, reads swallow `Mongo::Error`, writes let it raise).
2. **Model(s)** — plain POROs wrapping normalized Mongo docs (see
   `app/models/vulnerability.rb`).
3. **API controller** — `app/controllers/api/v1/<module>/...`,
   `< Api::V1::BaseController`.
4. **Routes** — a sibling block under `namespace :api { namespace :v1 { ... } }`
   in `web/config/routes.rb`, rooted appropriately for `/api/v1/<module>`.
5. **Web department** — a controller + views + a sidebar entry
   (`app/views/layouts/_sidebar.html.erb`).
6. **Tests** — controller integration (stub the service, no live Mongo), service
   unit tests (double the Mongo collection), model tests. Use the `stub_methods`
   helper in `test/test_helper.rb` (Minitest 6 dropped bundled mocks).

Prefer namespace-by-convention over Rails engines unless the user asks.

## Dev & test workflow

- Runs via **docker-compose** (Postgres + `mongo:8` + web with foreman /
  `Procfile.dev` for live reload). The Dockerfile/compose were adapted from the
  old "scope" project.
- Tests: `bin/rails test` from `web/`, needs a reachable Postgres `hunter_test`.
  **Mongo is doubled in tests** — no live Mongo required.
- Local bundle (outside Docker): the system gem dir isn't writable, so run
  `bundle config set --local path vendor/bundle && bundle install` (build tools +
  libpq are present). `vendor/bundle` and `.bundle/` are gitignored.

## Repo conventions

- **Commit author:** `Claude <noreply@anthropic.com>`.
- **Commit messages:** a single sentence, no body.
- Only commit when the user asks.

## Assistant capability change rule

Any new Assistant context type, tool, provider feature, user role, write action,
or execution action requires an approved threat-model delta before
implementation. The change must have a dedicated closed schema, dedicated
authorization, clear UI disclosure, metadata-only audit coverage, adversarial
tests with stable outcomes, and an explicit human-approval design for every
effectful operation.

Do not widen a generic tool to cover the new capability. Generic network,
search, shell, filesystem, credential, write, send, schedule, or execution
tools are prohibited. Wildcard scopes are prohibited for Assistant service and
turn-grant identities. A capability must remain narrowly named and independently
revocable, and production stays disabled until its review evidence is recorded
in the Assistant production checklist.

### Approved exceptions

- **Direct conversation organization: rename + reorder** (approved delta:
  `docs/superpowers/specs/2026-08-13-assistant-conversation-workspace-design.md`).
  The configured Assistant administrator may explicitly rename and reorder
  their own conversation history through the browser UI, conditioned on all of
  the following remaining true:
  - Rename and reorder remain separately named, session-only, same-origin CSRF
    protected routes with exact closed bodies. They never become a generic
    conversation update or bulk-write endpoint.
  - Every lookup and permutation is scoped to the human session owner. Reorder
    accepts only the complete current owned ID set and is atomic; rename can
    change only the bounded title.
  - The LLM receives no rename/reorder tool. Human submission, drag/drop, or a
    discrete move command is the approval for each effectful operation.
  - Both writes are independently revocable through
    `Assistant::Setting#conversation_management_enabled` and are
    metadata-only audited without titles, order arrays, messages, or provider
    output.
  - Production activation still requires review evidence in
    `docs/security/hunter-assistant-production-checklist.md`.

  Any wider metadata field, background/model-initiated organization, sharing,
  bulk mutation, or removal of owner/toggle/audit/closed-schema gates is a new
  capability change requiring another threat-model delta.

- **Administrator-equivalent operational access through Hunter MCP** (approved
  delta:
  `docs/superpowers/specs/2026-08-19-assistant-mcp-administrator-proxy-design.md`).
  Submitting a message as the configured Assistant administrator approves the
  model's use of every currently enabled, dedicated Hunter MCP capability
  reasonably necessary to fulfill that message, including non-secret creates,
  updates, validation, target resolution, Whiterabbit job submission,
  operational analysis, Ansible utility actions, run launch, monitoring, and
  cancellation. No second confirmation step is required, conditioned on all of
  the following remaining true:
  - Hunter MCP is the only Hunter access path. Every capability has a narrowly
    named tool, closed schemas, dedicated non-wildcard authorization, a live
    human-controlled feature gate, ordinary domain validation, stable errors,
    action receipts, and metadata-only audit. There is no generic API, network,
    shell, filesystem, database, credential, send, schedule, or execution tool.
  - Every current and future `/api/v1` operation is classified by the reviewed
    capability catalog as enabled, secret, delete, governance, machine identity,
    internal MCP backing, or an API alias. New operations stay unavailable until
    explicitly classified and implemented; OpenAPI never auto-registers tools.
  - Secret values are unavailable as both input and output. Credentials and
    secret variables expose safe metadata/opaque IDs only; the model cannot
    create, rotate, clear, reveal, or update secret material.
  - No MCP tool may issue HTTP `DELETE`, reach a destroy action/service, or
    destructively remove a Hunter record. Separately named reversible cancel,
    restore, or untrash operations are allowed only when their schemas and
    services cannot delete a record.
  - Assistant/security governance remains human-only. The model cannot change
    tools, scopes, gates, budgets, validators, audit, providers, authentication,
    users, roles, sessions, API tokens, retention, service identities, or
    runner/executor machine state.
  - Effects are attributed to the turn's human administrator, validated through
    existing domain services, idempotent against retries, concurrency-safe where
    records are editable, immediately revocable through live gates, disclosed
    in the UI, and audited without prompts, content, output, or secrets.
  - Production activation remains gated by review evidence in
    `docs/security/hunter-assistant-production-checklist.md`.

  Any relaxation of the permanent secret, deletion, governance, MCP-only,
  dedicated-tool, closed-schema, non-wildcard, revocation, validation,
  idempotency, attribution, disclosure, audit, or production-gate conditions is
  a new capability change requiring another approved threat-model delta.

- **Unrestricted Whiterabbit command authoring and execution** (approved delta:
  `docs/superpowers/specs/2026-08-23-unrestricted-whiterabbit-command-authoring-design.md`).
  The configured Assistant administrator may use any structurally valid
  executable name and arguments in templates created or edited through the
  dedicated Whiterabbit tools, and may submit those templates through the
  separately authorized job tool when their message requests it, conditioned
  on all of the following remaining true:
  - Validation still enforces closed schemas, bounds, operators, NUL/newline
    rejection, and Assistant secret-input detection; it performs no executable
    classification or allowlisting.
  - Template validation, create, edit, target resolution, and job submission
    remain separately named MCP tools with exact non-wildcard scopes, live
    human-controlled gates, budgets, idempotency, human attribution, action
    receipts, and metadata-only audit.
  - Selecting a shell, interpreter, privilege/container/file utility, custom
    binary, or future binary is explicitly permitted. The operator accepts that
    submitted jobs can cause arbitrary network, filesystem, process, privilege,
    destructive, or exfiltration effects available to the Whiterabbit worker.
  - This exception adds no generic MCP shell/network/filesystem/request/execution
    tool, no secret-value API, no Hunter record-destroy API, no governance tool,
    and no direct worker identity or callback access.
  - Production activation remains gated by candidate-specific evidence in
    `docs/security/hunter-assistant-production-checklist.md` and an independent
    review explicitly acknowledging arbitrary worker execution.

  Any wider direct execution path, removal of the remaining schema,
  authorization, revocation, budget, idempotency, attribution, disclosure,
  audit, or production gates, or expansion beyond the Whiterabbit workflow,
  requires another approved threat-model delta.
