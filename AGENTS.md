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

- **Approval-free create + explicit edit: Whiterabbit templates + Ansible
  playbooks** (approved delta:
  `docs/superpowers/specs/2026-07-30-assistant-mcp-full-access-authoring-design.md`).
  Create and explicit user-requested edit (never delete/run) of these two
  Control Center artifact types are approved **without** a confirmation step,
  conditioned on all of
  the following remaining true:
  - The strict content validators (`Assistant::DraftValidation::AnsibleStatic`
    for playbooks, `Assistant::DraftValidation::Whiterabbit`/`TemplateValidator`
    for templates) remain mandatory, fail-closed gates — no persist path may
    bypass them.
  - Create only builds a new record (`Model.new`) and never overwrites. Edit is
    separately named for every existing artifact, requires the artifact ID
    plus `expected_lock_version`, validates the complete merged artifact, and
    fails stale; there is no delete or run path.
  - Authorization is via dedicated, non-wildcard write scopes
    (`control_center_templates_write`, `control_center_templates_edit`,
    `control_center_ansible_write`, `control_center_ansible_edit`) granted only
    alongside the matching `create_*`/`edit_*` tool, and the whole capability is
    independently revocable via `Assistant::Setting#control_center_write_enabled`
    (default on) without touching any read capability.
  - Every create/edit is attributed to the turn's human user and audited
    metadata-only (`Assistant::Audit.record!`).
  - Production activation still stays gated by, and requires review evidence
    recorded in, the Assistant production checklist
    (`docs/security/hunter-assistant-production-checklist.md`) before enable.

  Any change to these conditions (new artifact type, delete/run, blind edit, a
  broadened or wildcard scope, or removing the validator/toggle/audit gates)
  is a new capability change requiring its own threat-model delta.
