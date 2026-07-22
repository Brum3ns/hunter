# Hunter API Documentation (OpenAPI + Swagger UI) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Hunter's `/api/v1` a scope-filtered machine-readable OpenAPI 3.1 document at `GET /api/v1/openapi.json` and a human-browsable, monochrome-skinned Swagger UI page at `/docs`, both driven from hand-written per-module YAML fragments, with Minitest drift/shape tests keeping the docs honest.

**Architecture:** Per-module OpenAPI YAML fragments live in `web/config/openapi/`. An `ApiDocs::Spec` module-function service deep-merges `base.yaml` with the fragments and filters them by token scope. `Api::V1::OpenapiController` renders that merged document (filtered to `Current.api_token&.scopes`). `DocsController` renders a full-width page booting vendored Swagger UI (static assets under `web/vendor/swagger-ui/`, served via Propshaft) against the JSON endpoint. A route-vs-spec drift test fails in both directions.

**Tech Stack:** Ruby 3.3.6, Rails 8, Propshaft, Tailwind CSS v4, Minitest. No new gems. Swagger UI vendored (pinned `swagger-ui-dist` 5.32.8), mirroring the `web/vendor/simple-icons` pattern. YAML parsed with stdlib `Psych`/`YAML`.

## Global Constraints

- **No new gems.** Everything uses the stdlib + existing Rails/Propshaft.
- **All work happens in `web/`** (the Rails app). Repo root is its parent.
- **Commit author:** `Claude <noreply@anthropic.com>` — commit with `git -c user.name='Claude' -c user.email='noreply@anthropic.com' commit -m "<message>"`.
- **Commit messages:** a single sentence, no body. **Only commit at the `Commit` step of each task.**
- **Tests:** run `bin/rails test` from `web/` (expects a reachable Postgres `hunter_test`; Mongo is doubled — no live Mongo). Use the `stub_methods(target, mapping) { ... }` helper from `test/test_helper.rb` for service stubbing (Minitest 6 dropped bundled mocks). Sign in with `sign_in_as(User)` / bearer tokens minted via `ApiToken.generate(user:, name:, scopes:)` → `[record, raw]`.
- **Module slug ↔ fragment file basename ↔ scope slug are the same string:** `cves`, `vulnerabilities`, `programs`, `targets`, `control_center`. `runner` is the one extra fragment with no matching module scope.
- **Error-envelope vocabulary (already implemented, document verbatim):** `401 {"error":"unauthorized"}`, `403 {"error":"invalid_csrf_token"}`, `403 {"error":"insufficient_scope"}`, `400 {"error":"bad_request","detail":...}`, `404 {"error":"not_found"}`, `502 {"error":"upstream_unavailable"}`.
- **Pagination (already implemented):** `page` (integer, floored at 1), `limit` (default 50, max 200) via `Api::V1::BaseController#pagination_page` / `#clamped_limit`.

---

## Reference: verified current API surface

The fragments must match these exact routes, params, envelopes, and serialization keys (confirmed against the code on 2026-07-13). Fragment tasks copy from here.

**Auth (`app/controllers/api/base_controller.rb`):** bearer (`Authorization: Bearer <token>` → `ApiToken.authenticate`) OR signed session cookie. Scope gating (`authorize_scope!`) applies **only to bearer tokens** and **only where the controller declares `api_scope`**; cookie/session and undeclared controllers pass through. `Current.api_token` is nil for cookie requests.

**Controllers that declare `api_scope`:** `cves` (`api_scope :cves`), `vulnerabilities` (`api_scope :vulnerabilities`). All others (`programs`, `targets`, `control_center`, `runner`) declare **no** scope.

**Routes block (`config/routes.rb`, the `namespace :api { namespace :v1 { ... } }` block only):**
```
GET    /api/v1/programs/changes                     programs/changes#index
GET    /api/v1/programs/runs                        programs/runs#index
GET    /api/v1/programs/runs/:id                    programs/runs#show           (id: /\d+/)
GET    /api/v1/vulnerabilities                       vulnerabilities#index
GET    /api/v1/vulnerabilities/:id                   vulnerabilities#show
POST   /api/v1/vulnerabilities                       vulnerabilities#create
PATCH  /api/v1/vulnerabilities/:id                   vulnerabilities#update
PUT    /api/v1/vulnerabilities/:id                   vulnerabilities#update
DELETE /api/v1/vulnerabilities/:id                   vulnerabilities#destroy
GET    /api/v1/targets                               targets#index
GET    /api/v1/targets/:id                           targets#show
GET    /api/v1/cves/new                              cves#new
GET    /api/v1/cves/config                           cves#filter_config
GET    /api/v1/cves                                  cves#index
GET    /api/v1/cves/:id                              cves#show
GET    /api/v1/control_center/templates              control_center/templates#index
POST   /api/v1/control_center/templates              control_center/templates#create
GET    /api/v1/control_center/templates/:id          control_center/templates#show
PATCH  /api/v1/control_center/templates/:id          control_center/templates#update
PUT    /api/v1/control_center/templates/:id          control_center/templates#update
DELETE /api/v1/control_center/templates/:id          control_center/templates#destroy
POST   /api/v1/control_center/templates/validate     control_center/templates#validate
POST   /api/v1/control_center/templates/validate_yaml control_center/templates#validate_yaml
GET    /api/v1/control_center/jobs                    control_center/jobs#index
GET    /api/v1/control_center/jobs/:id                control_center/jobs#show
POST   /api/v1/control_center/jobs                    control_center/jobs#create
GET    /api/v1/control_center/health                  control_center/health#show
GET    /api/v1/control_center/stats                   control_center/stats#show
POST   /api/v1/runner/jobs/claim                      runner/jobs#claim
POST   /api/v1/runner/jobs/:id/result                 runner/jobs#result
```
Plus the new route this plan adds: `GET /api/v1/openapi` (`openapi#show`).

**Serialization key sets (models):**
- `Cve#as_json`: full attributes — `id, osv_id, summary, details, published, modified, withdrawn, has_fix, severity_score, severity_level, first_seen_at, last_synced_at, aliases, severity, cwe_ids, ecosystems, languages, vendors, tags, affected, references, chain`.
- `Cve#as_core_json` (`fields=core`): `id, summary, severity_level, severity_score, ecosystems, languages, vendors, cwe_ids, tags, has_fix, published, modified, chain`.
- `Vulnerability#as_json`: raw Mongo doc; known sections `metadata, report, finding, target, poc` plus string `id`.
- `Target#as_json`: raw Mongo doc; known sections `metadata, target, http, headers, csp, fingerprint, tech` plus string `id`.
- `ProgramChange#as_feed_json`: `id, platform, program_sid, program_name, kind, old_value, new_value, detected_at, scope_run_id`.
- `ScopeRun#as_log_json`: `id, kind, platform, trigger, mode, bug_bounty, vdp, programs, success, in_flight, exit_status, duration_ms, stdout_bytes, stdout_excerpt, stderr_excerpt, error_class, started_at, finished_at, user`.
- Control center template `serialize`: `id, name, kind, tags, description, output, commands, target, created_by, yaml, created_at, updated_at`.
- Control center job `serialize`: `id, template_name, queue_name, target_count, status, exit_status, stdout, stderr, created_by, created_at`.
- CC health: `{ rabbitmq: {ok, detail}, mongo: {ok, detail} }`. CC stats: `{ totals, by_status, top_templates, by_queue, daily }`.

**Envelope shapes:** list endpoints for cves/vulnerabilities/targets → `{ count, page, limit, <plural>: [...] }`; `cves/new` → `{ limit, cves: [...], next_since, next_since_id }`; programs → `{ changes: [...] }` / `{ runs: [...] }`; CC index → `{ templates: [...] }` / `{ jobs: [...] }`.

---

## File Structure

**Created:**
- `web/vendor/swagger-ui/VERSION` — pinned version string.
- `web/vendor/swagger-ui/swagger-ui.css` — vendored Swagger UI stylesheet.
- `web/vendor/swagger-ui/swagger-ui-bundle.js` — vendored Swagger UI script.
- `web/config/openapi/base.yaml` — OpenAPI 3.1 skeleton (info, servers, securitySchemes, shared schemas).
- `web/config/openapi/cves.yaml` … `runner.yaml` — six per-module path/schema fragments.
- `web/app/services/api_docs/spec.rb` — merge + scope-filter service.
- `web/app/controllers/api/v1/openapi_controller.rb` — machine endpoint.
- `web/app/controllers/docs_controller.rb` — human page controller.
- `web/app/views/docs/index.html.erb` — Swagger UI mount + boot script.
- `web/app/assets/stylesheets/swagger_ui_skin.css` — monochrome skin (Propshaft-served).
- `web/test/services/api_docs/spec_test.rb` — service unit tests.
- `web/test/services/api_docs/coverage_test.rb` — drift + shape tests.
- `web/test/integration/api/v1/openapi_test.rb` — machine endpoint controller tests.
- `web/test/integration/docs_test.rb` — docs page + sidebar tests.

**Modified:**
- `web/config/initializers/assets.rb` — add `vendor/swagger-ui` to Propshaft paths.
- `web/config/routes.rb` — add `openapi` route (api/v1) + `docs` route (web).
- `web/app/helpers/navigation_helper.rb` — add API Docs entry to `utility_nav_items`.
- `web/app/helpers/icon_helper.rb` — add `code-bracket` heroicon path.
- `web/test/helpers/icon_helper_test.rb` — assert `code-bracket` renders (if the file enumerates icons).

---

### Task 1: Vendor Swagger UI static assets + Propshaft registration

**Files:**
- Create: `web/vendor/swagger-ui/VERSION`
- Create: `web/vendor/swagger-ui/swagger-ui.css`
- Create: `web/vendor/swagger-ui/swagger-ui-bundle.js`
- Modify: `web/config/initializers/assets.rb`

**Interfaces:**
- Produces: Propshaft logical asset names `swagger-ui.css` and `swagger-ui-bundle.js` (resolvable via `stylesheet_link_tag "swagger-ui"` / `javascript_include_tag "swagger-ui-bundle"`), consumed by Task 6.

- [x] **Step 1: Download and extract the two vendored files (pinned 5.32.8)**

Run from the repo root (`/home/claude/workspace`):
```bash
mkdir -p web/vendor/swagger-ui
cd /tmp
curl -sL https://registry.npmjs.org/swagger-ui-dist/-/swagger-ui-dist-5.32.8.tgz -o sw.tgz
tar -xzf sw.tgz package/swagger-ui.css package/swagger-ui-bundle.js
cp package/swagger-ui.css /home/claude/workspace/web/vendor/swagger-ui/swagger-ui.css
cp package/swagger-ui-bundle.js /home/claude/workspace/web/vendor/swagger-ui/swagger-ui-bundle.js
printf 'swagger-ui-dist 5.32.8\n' > /home/claude/workspace/web/vendor/swagger-ui/VERSION
```
Expected: two non-empty files under `web/vendor/swagger-ui/` plus `VERSION`. Verify:
```bash
ls -l /home/claude/workspace/web/vendor/swagger-ui/
```
Both `.css` and `.js` should be present and > 100 KB. (If the network is unavailable, fetch the same two files from any pinned `swagger-ui-dist@5.32.8` mirror — do not change the version string.)

- [x] **Step 2: Register the vendor directory with Propshaft**

Edit `web/config/initializers/assets.rb`, appending after the existing content:
```ruby
# Serve vendored Swagger UI (dist files, pinned — see vendor/swagger-ui/VERSION)
# through Propshaft, mirroring the vendor/simple-icons pattern. Referenced only
# by the /docs page.
Rails.application.config.assets.paths << Rails.root.join("vendor", "swagger-ui")
```

- [x] **Step 3: Verify Propshaft resolves the logical names**

Run from `web/`:
```bash
bin/rails runner 'puts Rails.application.assets.load_path.find("swagger-ui.css")&.path; puts Rails.application.assets.load_path.find("swagger-ui-bundle.js")&.path'
```
Expected: two absolute paths under `vendor/swagger-ui/` printed (not `nil`). If your Propshaft version lacks `.assets.load_path.find`, instead verify with `bin/rails runner 'puts Rails.application.config.assets.paths.grep(/swagger-ui/)'` (prints the registered path).

- [x] **Step 4: Commit**

```bash
cd /home/claude/workspace
git add web/vendor/swagger-ui web/config/initializers/assets.rb
git -c user.name='Claude' -c user.email='noreply@anthropic.com' commit -m "Vendor pinned Swagger UI dist assets and register them with Propshaft"
```

---

### Task 2: `ApiDocs::Spec` merge + scope-filter service, and `base.yaml`

**Files:**
- Create: `web/config/openapi/base.yaml`
- Create: `web/app/services/api_docs/spec.rb`
- Test: `web/test/services/api_docs/spec_test.rb`

**Interfaces:**
- Produces:
  - `ApiDocs::Spec.document(scopes: nil, dir: DEFAULT_DIR) -> Hash` — merged OpenAPI document. `scopes: nil` or a list containing `"*"` → all fragments; otherwise only fragments whose basename is in `scopes`. `dir` overridable for tests.
  - `ApiDocs::Spec::DEFAULT_DIR` — `Rails.root.join("config", "openapi")`.
  - Raises `ApiDocs::Spec::DuplicateKeyError` (a `StandardError` subclass) on duplicate path or schema keys across fragments.
- Consumes: `base.yaml` skeleton + fragment files (added in later tasks).

- [x] **Step 1: Write `base.yaml` skeleton**

Create `web/config/openapi/base.yaml`:
```yaml
openapi: "3.1.0"
info:
  title: "Hunter API"
  version: "1.0.0"
  description: |
    JSON API for the Hunter bug-bounty dashboard, grouped by module
    (CVEs, Vulnerabilities, Programs, Targets, Control Center, Runner).

    ## Authentication
    Every endpoint requires authentication by **either**:
    - a signed **session cookie** (browser; CSRF-protected), or
    - an `Authorization: Bearer <token>` header (external clients; CSRF is
      skipped because there is no cookie and thus no forgery risk).

    Mint bearer tokens with `bin/rails api_tokens:create USERNAME=<u>
    NAME=<label> SCOPES=cves,programs`.

    ## Token scopes
    Bearer tokens carry `scopes` (module slugs, or `*` for all). A request to a
    scoped endpoint with a token lacking that scope returns
    `403 insufficient_scope`. Session-cookie requests are never scope-gated.
    This document is filtered to the calling token's scopes, so a `cves`-only
    token downloads only the CVE endpoints.

    ## Try-it-out
    `GET` requests work with your session cookie. **Write** requests
    (POST/PATCH/DELETE) require a bearer token pasted into the Authorize
    dialog — a cookie POST without a CSRF token is rejected as
    `403 invalid_csrf_token`.

    ## Error envelopes
    Errors share a JSON shape `{ "error": "<code>" }` (some add `detail`):
    `401 unauthorized`, `403 invalid_csrf_token`, `403 insufficient_scope`,
    `400 bad_request`, `404 not_found`, `502 upstream_unavailable` (Mongo
    write failure). Mongo *read* failures degrade to an empty result set.
servers:
  - url: "/"
    description: "This Hunter instance"
components:
  securitySchemes:
    bearerAuth:
      type: http
      scheme: bearer
      description: "An API token minted via bin/rails api_tokens:create."
  schemas:
    Error:
      type: object
      properties:
        error:
          type: string
          description: "Machine-readable error code."
          examples: ["unauthorized", "insufficient_scope", "not_found"]
        detail:
          type: string
          description: "Human-readable detail (bad_request only)."
      required: ["error"]
    PageEnvelope:
      type: object
      description: "Offset-paginated list envelope (the plural data key varies by module)."
      properties:
        count:
          type: integer
          description: "Total matching documents across all pages."
        page:
          type: integer
          description: "1-based page number (floored at 1)."
        limit:
          type: integer
          description: "Page size actually applied (default 50, max 200)."
      required: ["count", "page", "limit"]
security:
  - bearerAuth: []
```

- [x] **Step 2: Write the failing service test**

Create `web/test/services/api_docs/spec_test.rb`:
```ruby
require "test_helper"

class ApiDocs::SpecTest < ActiveSupport::TestCase
  # Hermetic fixture dir: base.yaml + two tiny fragments, so these tests do not
  # depend on the real per-module fragments (which other tasks flesh out).
  def with_fixture_dir
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "base.yaml"), <<~YAML)
        openapi: "3.1.0"
        info: { title: "T", version: "1.0.0" }
        components: { schemas: { Error: { type: object } } }
        paths: {}
      YAML
      File.write(File.join(dir, "cves.yaml"), <<~YAML)
        paths:
          /api/v1/cves: { get: { summary: "list cves", tags: ["CVEs"] } }
        components:
          schemas: { Cve: { type: object } }
      YAML
      File.write(File.join(dir, "programs.yaml"), <<~YAML)
        paths:
          /api/v1/programs/changes: { get: { summary: "changes", tags: ["Programs"] } }
        components:
          schemas: { ProgramChange: { type: object } }
      YAML
      yield dir
    end
  end

  test "nil scopes merges every fragment into base" do
    with_fixture_dir do |dir|
      doc = ApiDocs::Spec.document(scopes: nil, dir: dir)
      assert_equal "3.1.0", doc["openapi"]
      assert doc["paths"].key?("/api/v1/cves")
      assert doc["paths"].key?("/api/v1/programs/changes")
      assert doc["components"]["schemas"].key?("Error")
      assert doc["components"]["schemas"].key?("Cve")
      assert doc["components"]["schemas"].key?("ProgramChange")
    end
  end

  test "wildcard scope merges every fragment" do
    with_fixture_dir do |dir|
      doc = ApiDocs::Spec.document(scopes: ["*"], dir: dir)
      assert doc["paths"].key?("/api/v1/cves")
      assert doc["paths"].key?("/api/v1/programs/changes")
    end
  end

  test "a named scope includes only that fragment plus base" do
    with_fixture_dir do |dir|
      doc = ApiDocs::Spec.document(scopes: ["cves"], dir: dir)
      assert doc["paths"].key?("/api/v1/cves")
      refute doc["paths"].key?("/api/v1/programs/changes")
      assert doc["components"]["schemas"].key?("Cve")
      refute doc["components"]["schemas"].key?("ProgramChange")
      assert doc["components"]["schemas"].key?("Error"), "base schemas always present"
    end
  end

  test "duplicate path keys across fragments raise" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "base.yaml"), "openapi: \"3.1.0\"\npaths: {}\n")
      File.write(File.join(dir, "a.yaml"), "paths:\n  /x: { get: { summary: s } }\n")
      File.write(File.join(dir, "b.yaml"), "paths:\n  /x: { post: { summary: s } }\n")
      assert_raises(ApiDocs::Spec::DuplicateKeyError) do
        ApiDocs::Spec.document(scopes: nil, dir: dir)
      end
    end
  end
end
```

- [x] **Step 2b: Run it to verify it fails**

Run from `web/`:
```bash
bin/rails test test/services/api_docs/spec_test.rb
```
Expected: FAIL — `uninitialized constant ApiDocs` (or similar).

- [x] **Step 3: Implement the service**

Create `web/app/services/api_docs/spec.rb`:
```ruby
require "yaml"

# Builds Hunter's OpenAPI document by deep-merging config/openapi/base.yaml with
# one YAML fragment per module. The document is filtered to a caller's token
# scopes so a scoped bearer token downloads only the endpoints it may use.
#
# Adding a module later is a drop-in: create config/openapi/<module>.yaml. This
# service never needs editing. Fragment basename == module slug == scope slug.
module ApiDocs
  module Spec
    module_function

    DEFAULT_DIR = -> { Rails.root.join("config", "openapi") }

    class DuplicateKeyError < StandardError; end

    # Returns the merged OpenAPI document (a Hash with string keys).
    # scopes: nil or a list containing "*" -> all fragments; otherwise only
    # fragments whose file basename is listed.
    def document(scopes: nil, dir: nil)
      dir = Pathname(dir || DEFAULT_DIR.call)
      return build(dir, scopes) if Rails.env.development?

      @cache ||= {}
      @cache[[dir.to_s, cache_key(scopes)]] ||= build(dir, scopes)
    end

    def cache_key(scopes)
      scopes.nil? ? "*" : scopes.sort.join(",")
    end

    def build(dir, scopes)
      doc = load_yaml(dir.join("base.yaml"))
      doc["paths"] ||= {}
      doc["components"] ||= {}
      doc["components"]["schemas"] ||= {}

      fragment_files(dir, scopes).each do |file|
        fragment = load_yaml(file)
        merge_section!(doc["paths"], fragment["paths"], file, "paths")
        schemas = fragment.dig("components", "schemas")
        merge_section!(doc["components"]["schemas"], schemas, file, "schemas")
      end
      doc
    end

    # Every *.yaml except base.yaml, filtered by scope. All fragments when
    # scopes is nil or contains "*".
    def fragment_files(dir, scopes)
      all = Dir.glob(dir.join("*.yaml")).reject { |f| File.basename(f) == "base.yaml" }.sort
      return all if scopes.nil? || scopes.include?("*")

      wanted = Array(scopes).map(&:to_s)
      all.select { |f| wanted.include?(File.basename(f, ".yaml")) }
    end

    def merge_section!(into, from, file, label)
      return if from.nil?

      from.each do |key, value|
        if into.key?(key)
          raise DuplicateKeyError, "duplicate #{label} key #{key.inspect} in #{File.basename(file)}"
        end
        into[key] = value
      end
    end

    def load_yaml(path)
      YAML.safe_load(File.read(path), aliases: true) || {}
    end
  end
end
```

- [x] **Step 4: Run the test to verify it passes**

Run from `web/`:
```bash
bin/rails test test/services/api_docs/spec_test.rb
```
Expected: PASS (4 tests, 0 failures). If `Dir.mktmpdir` is undefined, add `require "tmpdir"` at the top of the test file.

- [x] **Step 5: Commit**

```bash
cd /home/claude/workspace
git add web/config/openapi/base.yaml web/app/services/api_docs/spec.rb web/test/services/api_docs/spec_test.rb
git -c user.name='Claude' -c user.email='noreply@anthropic.com' commit -m "Add the ApiDocs::Spec merge and scope-filter service with the OpenAPI base skeleton"
```

---

### Task 3: Machine endpoint `GET /api/v1/openapi.json` + the CVE fragment

**Files:**
- Create: `web/config/openapi/cves.yaml`
- Create: `web/app/controllers/api/v1/openapi_controller.rb`
- Modify: `web/config/routes.rb` (api/v1 namespace)
- Test: `web/test/integration/api/v1/openapi_test.rb`

**Interfaces:**
- Consumes: `ApiDocs::Spec.document(scopes:)` from Task 2.
- Produces: `GET /api/v1/openapi` (alias `.json`) → merged, scope-filtered document as JSON. Route helper `api_v1_openapi_path`. The CVE fragment establishes the content-depth pattern later fragments follow.

- [x] **Step 1: Write the CVE fragment (full depth — the LLM-self-serve module)**

Create `web/config/openapi/cves.yaml`:
```yaml
paths:
  /api/v1/cves:
    get:
      tags: ["CVEs"]
      x-api-scope: cves
      summary: "List CVEs"
      description: |
        Browse tracked CVEs, newest-modified first. Filters combine with AND.
        Multi-value filters accept a comma-separated list (matched as `$in`).
        A bearer token's saved `cve_filter` supplies defaults; request params
        override it per field.
      parameters:
        - { name: ecosystem, in: query, schema: { type: string }, description: "OSV ecosystem(s), e.g. `PyPI,npm`." }
        - { name: package, in: query, schema: { type: string }, description: "Affected package name(s)." }
        - { name: language, in: query, schema: { type: string }, description: "Language tag(s)." }
        - { name: vendor, in: query, schema: { type: string }, description: "Vendor(s)." }
        - { name: cwe, in: query, schema: { type: string }, description: "CWE id(s), e.g. `CWE-79`." }
        - { name: tag, in: query, schema: { type: string }, description: "Free-form tag(s)." }
        - { name: has_fix, in: query, schema: { type: boolean }, description: "Only CVEs with (true) / without (false) a known fix." }
        - name: min_severity
          in: query
          schema: { type: string, enum: [critical, high, medium, low] }
          description: "Minimum CVSS band: critical ≥9.0, high ≥7.0, medium ≥4.0, low ≥0.1."
        - { name: published_after, in: query, schema: { type: string, format: date-time }, description: "ISO-8601; keep CVEs published at/after this instant." }
        - { name: modified_after, in: query, schema: { type: string, format: date-time }, description: "ISO-8601; keep CVEs modified at/after this instant." }
        - { name: q, in: query, schema: { type: string }, description: "Case-insensitive text search over id, summary, details. Alias: `keyword`." }
        - name: fields
          in: query
          schema: { type: string, enum: [core] }
          description: "`core` returns the compact LLM serialization (drops the large `details` body); omit for the full document."
        - { name: page, in: query, schema: { type: integer, default: 1, minimum: 1 } }
        - { name: limit, in: query, schema: { type: integer, default: 50, maximum: 200 } }
      responses:
        "200":
          description: "Paginated CVE list."
          content:
            application/json:
              schema:
                allOf:
                  - $ref: "#/components/schemas/PageEnvelope"
                  - type: object
                    properties:
                      cves:
                        type: array
                        items: { $ref: "#/components/schemas/Cve" }
              example:
                count: 128
                page: 1
                limit: 50
                cves:
                  - id: "CVE-2024-1234"
                    summary: "Example RCE in acme-lib"
                    severity_level: "high"
                    severity_score: 8.1
                    has_fix: true
        "401": { $ref: "#/components/responses/Unauthorized" }
        "403": { $ref: "#/components/responses/InsufficientScope" }
  /api/v1/cves/{id}:
    get:
      tags: ["CVEs"]
      x-api-scope: cves
      summary: "Get one CVE"
      description: "Fetch a single CVE by its id (e.g. `CVE-2024-1234`). Always returns the full document; `fields=core` does not apply here."
      parameters:
        - { name: id, in: path, required: true, schema: { type: string }, description: "The CVE id." }
      responses:
        "200":
          description: "The full CVE document."
          content: { application/json: { schema: { $ref: "#/components/schemas/Cve" } } }
        "401": { $ref: "#/components/responses/Unauthorized" }
        "403": { $ref: "#/components/responses/InsufficientScope" }
        "404": { $ref: "#/components/responses/NotFound" }
  /api/v1/cves/new:
    get:
      tags: ["CVEs"]
      x-api-scope: cves
      summary: "New-since feed (keyset)"
      description: |
        LLM-facing incremental feed ordered by `first_seen_at` ascending. Poll
        by echoing the previous response's `next_since` / `next_since_id` back
        as `since` / `since_id`; an empty page returns `next_since: null`. All
        list filters (plus the token's saved filter) also apply. Pair with
        `fields=core` for compact payloads.
      parameters:
        - { name: since, in: query, schema: { type: string, format: date-time }, description: "ISO-8601 lower bound on first_seen_at (exclusive at the tiebreaker)." }
        - { name: since_id, in: query, schema: { type: string }, description: "Tiebreaker CVE id for rows sharing the `since` instant." }
        - { name: fields, in: query, schema: { type: string, enum: [core] } }
        - { name: limit, in: query, schema: { type: integer, default: 50, maximum: 200 } }
        - { name: ecosystem, in: query, schema: { type: string } }
        - { name: package, in: query, schema: { type: string } }
        - { name: min_severity, in: query, schema: { type: string, enum: [critical, high, medium, low] } }
        - { name: q, in: query, schema: { type: string } }
      responses:
        "200":
          description: "A page of newly-seen CVEs plus the next cursor."
          content:
            application/json:
              schema:
                type: object
                properties:
                  limit: { type: integer }
                  cves: { type: array, items: { $ref: "#/components/schemas/Cve" } }
                  next_since: { type: [string, "null"], format: date-time }
                  next_since_id: { type: [string, "null"] }
                required: [limit, cves, next_since, next_since_id]
        "401": { $ref: "#/components/responses/Unauthorized" }
        "403": { $ref: "#/components/responses/InsufficientScope" }
  /api/v1/cves/config:
    get:
      tags: ["CVEs"]
      x-api-scope: cves
      summary: "Echo the token's saved CVE filter"
      description: "Returns the calling bearer token's saved `cve_filter` (the defaults applied to `/cves` and `/cves/new`). Session requests get `{}`."
      responses:
        "200":
          description: "The saved filter."
          content:
            application/json:
              schema:
                type: object
                properties:
                  cve_filter: { type: object, additionalProperties: true }
                required: [cve_filter]
        "401": { $ref: "#/components/responses/Unauthorized" }
        "403": { $ref: "#/components/responses/InsufficientScope" }
components:
  schemas:
    Cve:
      type: object
      description: "A tracked CVE (normalized OSV document). Extra keys may appear; `fields=core` returns the subset marked core."
      additionalProperties: true
      properties:
        id: { type: string, description: "CVE id (primary key), e.g. CVE-2024-1234." }
        osv_id: { type: string }
        summary: { type: string, description: "[core] Short title." }
        details: { type: string, description: "Full markdown body (omitted by fields=core)." }
        published: { type: string, format: date-time }
        modified: { type: string, format: date-time }
        withdrawn: { type: [string, "null"], format: date-time }
        has_fix: { type: boolean }
        severity_score: { type: [number, "null"], description: "[core] CVSS base score." }
        severity_level: { type: [string, "null"], description: "[core] critical|high|medium|low." }
        first_seen_at: { type: string, format: date-time, description: "When Hunter first ingested it (the /cves/new sort key)." }
        last_synced_at: { type: string, format: date-time }
        aliases: { type: array, items: { type: string } }
        severity: { type: array, items: { type: object, additionalProperties: true } }
        cwe_ids: { type: array, items: { type: string }, description: "[core]" }
        ecosystems: { type: array, items: { type: string }, description: "[core]" }
        languages: { type: array, items: { type: string }, description: "[core]" }
        vendors: { type: array, items: { type: string }, description: "[core]" }
        tags: { type: array, items: { type: string }, description: "[core]" }
        affected: { type: array, items: { type: object, additionalProperties: true } }
        references: { type: array, items: { type: object, additionalProperties: true } }
        chain: { type: object, additionalProperties: true, description: "[core] Derived exploit/context chain." }
      required: [id]
```

- [x] **Step 2: Add the shared reusable responses to `base.yaml`**

The CVE fragment `$ref`s `#/components/responses/*`. Add a `responses` block under `components` in `web/config/openapi/base.yaml` (insert after the `schemas:` block, still under `components:`):
```yaml
  responses:
    Unauthorized:
      description: "Missing or invalid authentication."
      content: { application/json: { schema: { $ref: "#/components/schemas/Error" }, example: { error: "unauthorized" } } }
    InsufficientScope:
      description: "The bearer token lacks the required scope."
      content: { application/json: { schema: { $ref: "#/components/schemas/Error" }, example: { error: "insufficient_scope" } } }
    NotFound:
      description: "No matching resource."
      content: { application/json: { schema: { $ref: "#/components/schemas/Error" }, example: { error: "not_found" } } }
    BadRequest:
      description: "Malformed or missing parameters."
      content: { application/json: { schema: { $ref: "#/components/schemas/Error" }, example: { error: "bad_request", detail: "param is missing" } } }
    UpstreamUnavailable:
      description: "A Mongo write failed."
      content: { application/json: { schema: { $ref: "#/components/schemas/Error" }, example: { error: "upstream_unavailable" } } }
    CcUnprocessable:
      description: "Validation failed (control center template/job)."
      content: { application/json: { schema: { type: object, properties: { error: { type: string }, detail: { type: array, items: { type: string } } }, required: [error, detail] }, example: { error: "unprocessable_entity", detail: ["name can't be blank"] } } }
```
`components.responses` lives ONLY in `base.yaml` (the service merges `paths` + `components.schemas` from fragments, so a fragment's `components.responses` would be silently dropped). Every fragment `$ref`s these shared responses; no fragment redefines them. `CcUnprocessable` is placed here (not in `control_center.yaml`) for exactly this reason.

- [x] **Step 3: Write the failing controller test**

Create `web/test/integration/api/v1/openapi_test.rb`:
```ruby
require "test_helper"

class Api::V1::OpenapiTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }

  test "401 without a cookie or token" do
    get "/api/v1/openapi.json"
    assert_response :unauthorized
    assert_equal "unauthorized", JSON.parse(response.body)["error"]
  end

  test "session request gets the full document with every module tag" do
    sign_in_as(@user)
    get "/api/v1/openapi.json"
    assert_response :success
    doc = JSON.parse(response.body)
    assert_equal "3.1.0", doc["openapi"]
    assert doc["paths"].key?("/api/v1/cves"), "cves documented"
    assert doc["paths"].key?("/api/v1/vulnerabilities"), "vulnerabilities documented"
    assert doc["paths"].key?("/api/v1/programs/changes"), "programs documented"
  end

  test "cves-scoped bearer gets only CVE paths" do
    _rec, raw = ApiToken.generate(user: @user, name: "llm", scopes: ["cves"])
    get "/api/v1/openapi.json", headers: { "Authorization" => "Bearer #{raw}" }
    assert_response :success
    doc = JSON.parse(response.body)
    assert doc["paths"].key?("/api/v1/cves")
    refute doc["paths"].key?("/api/v1/vulnerabilities")
    refute doc["paths"].key?("/api/v1/programs/changes")
  end

  test "the .json-less canonical path also resolves" do
    sign_in_as(@user)
    get "/api/v1/openapi"
    assert_response :success
    assert_equal "3.1.0", JSON.parse(response.body)["openapi"]
  end
end
```

- [x] **Step 3b: Run it to verify it fails**

Run from `web/`:
```bash
bin/rails test test/integration/api/v1/openapi_test.rb
```
Expected: FAIL — routing error / no route matches `/api/v1/openapi.json`.

- [x] **Step 4: Add the controller**

Create `web/app/controllers/api/v1/openapi_controller.rb`:
```ruby
module Api
  module V1
    # Serves the machine-readable OpenAPI document, filtered to the caller's
    # token scopes. No api_scope declaration: every authenticated caller may
    # read it (sessions and wildcard tokens get the whole document).
    class OpenapiController < Api::V1::BaseController
      def show
        render json: ApiDocs::Spec.document(scopes: Current.api_token&.scopes)
      end
    end
  end
end
```

- [x] **Step 5: Add the route**

In `web/config/routes.rb`, inside the `namespace :api do namespace :v1 do ... end end` block, add a line (place it near the top of the v1 block, before the module namespaces):
```ruby
    # Machine-readable OpenAPI document (scope-filtered per token). Canonical
    # URL /api/v1/openapi; the .json suffix also resolves.
    get "openapi", to: "openapi#show"
```

- [x] **Step 6: Run the controller test to verify it passes**

Run from `web/`:
```bash
bin/rails test test/integration/api/v1/openapi_test.rb
```
Expected: PASS (4 tests). If `Current.api_token&.scopes` returns nil for a wildcard token, confirm the token's `scopes` column defaults to `["*"]` (it does via `ApiToken.generate`). Session requests have `Current.api_token == nil` → `document(scopes: nil)` → full doc, which is correct.

- [x] **Step 7: Commit**

```bash
cd /home/claude/workspace
git add web/config/openapi/cves.yaml web/config/openapi/base.yaml web/app/controllers/api/v1/openapi_controller.rb web/config/routes.rb web/test/integration/api/v1/openapi_test.rb
git -c user.name='Claude' -c user.email='noreply@anthropic.com' commit -m "Serve the scope-filtered OpenAPI document at /api/v1/openapi with the full CVE fragment"
```

---

### Task 4: Remaining module fragments (vulnerabilities, programs, targets, control_center, runner)

**Files:**
- Create: `web/config/openapi/vulnerabilities.yaml`
- Create: `web/config/openapi/programs.yaml`
- Create: `web/config/openapi/targets.yaml`
- Create: `web/config/openapi/control_center.yaml`
- Create: `web/config/openapi/runner.yaml`

**Interfaces:**
- Consumes: `base.yaml` shared `responses`/`schemas` (via `$ref`).
- Produces: complete `paths` + `components.schemas` for every remaining `/api/v1` route in the reference table. Consumed by the Task 5 drift test (which fails if any route is missing).

> Every operation MUST carry `tags`, `summary`, `description`, and — only where the controller declares one — `x-api-scope`. Only `vulnerabilities` declares a scope among these (`vulnerabilities`). `programs`, `targets`, `control_center`, `runner` declare **none**, so their operations must **omit** `x-api-scope` (the shape test asserts this).

- [x] **Step 1: Write `vulnerabilities.yaml`**

Create `web/config/openapi/vulnerabilities.yaml`:
```yaml
paths:
  /api/v1/vulnerabilities:
    get:
      tags: ["Vulnerabilities"]
      x-api-scope: vulnerabilities
      summary: "List vulnerabilities"
      description: "Browse findings, newest first. Filters combine with AND; `q` is a case-insensitive search over finding name and target host."
      parameters:
        - { name: program, in: query, schema: { type: string }, description: "metadata.program." }
        - { name: severity, in: query, schema: { type: string }, description: "finding.severity." }
        - { name: status, in: query, schema: { type: string }, description: "report.status." }
        - { name: tool, in: query, schema: { type: string }, description: "metadata.tool." }
        - { name: q, in: query, schema: { type: string }, description: "Text search over finding.name and target.host." }
        - { name: page, in: query, schema: { type: integer, default: 1, minimum: 1 } }
        - { name: limit, in: query, schema: { type: integer, default: 50, maximum: 200 } }
      responses:
        "200":
          description: "Paginated vulnerability list."
          content:
            application/json:
              schema:
                allOf:
                  - $ref: "#/components/schemas/PageEnvelope"
                  - type: object
                    properties:
                      vulnerabilities: { type: array, items: { $ref: "#/components/schemas/Vulnerability" } }
        "401": { $ref: "#/components/responses/Unauthorized" }
        "403": { $ref: "#/components/responses/InsufficientScope" }
        "502": { $ref: "#/components/responses/UpstreamUnavailable" }
    post:
      tags: ["Vulnerabilities"]
      x-api-scope: vulnerabilities
      summary: "Create a vulnerability"
      description: "Store an arbitrary well-formed finding document. Any client-supplied `id`/`_id` is stripped."
      requestBody:
        required: true
        content: { application/json: { schema: { $ref: "#/components/schemas/Vulnerability" } } }
      responses:
        "201":
          description: "Created; returns the new id."
          content: { application/json: { schema: { type: object, properties: { id: { type: string } }, required: [id] } } }
        "400": { $ref: "#/components/responses/BadRequest" }
        "401": { $ref: "#/components/responses/Unauthorized" }
        "403": { $ref: "#/components/responses/InsufficientScope" }
        "502": { $ref: "#/components/responses/UpstreamUnavailable" }
  /api/v1/vulnerabilities/{id}:
    parameters:
      - { name: id, in: path, required: true, schema: { type: string }, description: "Mongo ObjectId string." }
    get:
      tags: ["Vulnerabilities"]
      x-api-scope: vulnerabilities
      summary: "Get one vulnerability"
      description: "Fetch a finding by ObjectId. An invalid ObjectId yields 404."
      responses:
        "200": { description: "The finding.", content: { application/json: { schema: { $ref: "#/components/schemas/Vulnerability" } } } }
        "401": { $ref: "#/components/responses/Unauthorized" }
        "403": { $ref: "#/components/responses/InsufficientScope" }
        "404": { $ref: "#/components/responses/NotFound" }
    patch:
      tags: ["Vulnerabilities"]
      x-api-scope: vulnerabilities
      summary: "Update a vulnerability"
      description: "`$set` the supplied fields on an existing finding, then return the updated document."
      requestBody:
        required: true
        content: { application/json: { schema: { $ref: "#/components/schemas/Vulnerability" } } }
      responses:
        "200": { description: "The updated finding.", content: { application/json: { schema: { $ref: "#/components/schemas/Vulnerability" } } } }
        "401": { $ref: "#/components/responses/Unauthorized" }
        "403": { $ref: "#/components/responses/InsufficientScope" }
        "404": { $ref: "#/components/responses/NotFound" }
        "502": { $ref: "#/components/responses/UpstreamUnavailable" }
    put:
      tags: ["Vulnerabilities"]
      x-api-scope: vulnerabilities
      summary: "Update a vulnerability (PUT alias)"
      description: "Identical to PATCH; `$set` the supplied fields and return the updated document."
      requestBody:
        required: true
        content: { application/json: { schema: { $ref: "#/components/schemas/Vulnerability" } } }
      responses:
        "200": { description: "The updated finding.", content: { application/json: { schema: { $ref: "#/components/schemas/Vulnerability" } } } }
        "401": { $ref: "#/components/responses/Unauthorized" }
        "403": { $ref: "#/components/responses/InsufficientScope" }
        "404": { $ref: "#/components/responses/NotFound" }
        "502": { $ref: "#/components/responses/UpstreamUnavailable" }
    delete:
      tags: ["Vulnerabilities"]
      x-api-scope: vulnerabilities
      summary: "Delete a vulnerability"
      description: "Remove a finding. Returns 204 on success."
      responses:
        "204": { description: "Deleted." }
        "401": { $ref: "#/components/responses/Unauthorized" }
        "403": { $ref: "#/components/responses/InsufficientScope" }
        "404": { $ref: "#/components/responses/NotFound" }
        "502": { $ref: "#/components/responses/UpstreamUnavailable" }
components:
  schemas:
    Vulnerability:
      type: object
      description: "A finding document (raw normalized Mongo doc; extra keys allowed)."
      additionalProperties: true
      properties:
        id: { type: string, description: "Mongo ObjectId (surfaced from _id)." }
        metadata: { type: object, additionalProperties: true, description: "program, tool, date, …" }
        report: { type: object, additionalProperties: true, description: "status and reporting fields." }
        finding: { type: object, additionalProperties: true, description: "name, severity, description." }
        target: { type: object, additionalProperties: true, description: "host and location." }
        poc: { type: object, additionalProperties: true, description: "proof-of-concept detail." }
```

- [x] **Step 2: Write `programs.yaml`** (no `x-api-scope` — controller declares none)

Create `web/config/openapi/programs.yaml`:
```yaml
paths:
  /api/v1/programs/changes:
    get:
      tags: ["Programs"]
      summary: "Program change feed"
      description: "The Monitor feed of scope/bounty/status changes for the current user's programs, newest first. Use `since_id` to tail new rows or `before_id` to load older ones."
      parameters:
        - { name: platform, in: query, schema: { type: string } }
        - name: kind
          in: query
          schema: { type: string, enum: [program_added, program_removed, bounty_changed, status_changed, scope_added, scope_removed, outofscope_added, outofscope_removed] }
        - { name: sid, in: query, schema: { type: string }, description: "Program sid." }
        - { name: since_id, in: query, schema: { type: integer }, description: "Return rows with id greater than this (live tail)." }
        - { name: before_id, in: query, schema: { type: integer }, description: "Return rows with id less than this (load older)." }
        - { name: limit, in: query, schema: { type: integer, default: 50, maximum: 200 } }
      responses:
        "200":
          description: "Change rows."
          content:
            application/json:
              schema:
                type: object
                properties:
                  changes: { type: array, items: { $ref: "#/components/schemas/ProgramChange" } }
                required: [changes]
        "401": { $ref: "#/components/responses/Unauthorized" }
  /api/v1/programs/runs:
    get:
      tags: ["Programs"]
      summary: "Scope-run log feed"
      description: "The Logs feed of scope tool runs, newest first. Runs are shared across operators unless `mine` is set."
      parameters:
        - { name: mine, in: query, schema: { type: boolean }, description: "Restrict to the current user's runs." }
        - { name: kind, in: query, schema: { type: string, enum: [fetch, version, status, check_mongo] } }
        - { name: platform, in: query, schema: { type: string } }
        - { name: status, in: query, schema: { type: string, enum: [ok] }, description: "`ok` keeps successes; any other value keeps failures." }
        - { name: since_id, in: query, schema: { type: integer }, description: "Rows with id greater than this, plus still-in-flight rows." }
        - { name: before_id, in: query, schema: { type: integer } }
        - { name: limit, in: query, schema: { type: integer, default: 50, maximum: 200 } }
      responses:
        "200":
          description: "Run rows."
          content:
            application/json:
              schema:
                type: object
                properties:
                  runs: { type: array, items: { $ref: "#/components/schemas/ScopeRun" } }
                required: [runs]
        "401": { $ref: "#/components/responses/Unauthorized" }
  /api/v1/programs/runs/{id}:
    get:
      tags: ["Programs"]
      summary: "Get one scope run"
      description: "Fetch a single run. Own runs are private; system runs (no user) are visible to any operator."
      parameters:
        - { name: id, in: path, required: true, schema: { type: integer } }
      responses:
        "200": { description: "The run.", content: { application/json: { schema: { $ref: "#/components/schemas/ScopeRun" } } } }
        "401": { $ref: "#/components/responses/Unauthorized" }
        "404": { $ref: "#/components/responses/NotFound" }
components:
  schemas:
    ProgramChange:
      type: object
      properties:
        id: { type: integer }
        platform: { type: string }
        program_sid: { type: string }
        program_name: { type: string }
        kind: { type: string }
        old_value: { type: [string, "null"] }
        new_value: { type: [string, "null"] }
        detected_at: { type: [string, "null"], format: date-time }
        scope_run_id: { type: [integer, "null"] }
    ScopeRun:
      type: object
      properties:
        id: { type: integer }
        kind: { type: string }
        platform: { type: [string, "null"] }
        trigger: { type: string, enum: [manual, scheduled] }
        mode: { type: [string, "null"] }
        bug_bounty: { type: [boolean, "null"] }
        vdp: { type: [boolean, "null"] }
        programs: { type: [array, "null"], items: { type: string } }
        success: { type: [boolean, "null"] }
        in_flight: { type: boolean }
        exit_status: { type: [integer, "null"] }
        duration_ms: { type: [integer, "null"] }
        stdout_bytes: { type: [integer, "null"] }
        stdout_excerpt: { type: [string, "null"] }
        stderr_excerpt: { type: [string, "null"] }
        error_class: { type: [string, "null"] }
        started_at: { type: [string, "null"], format: date-time }
        finished_at: { type: [string, "null"], format: date-time }
        user: { type: [string, "null"] }
```

- [x] **Step 3: Write `targets.yaml`** (no `x-api-scope`)

Create `web/config/openapi/targets.yaml`:
```yaml
paths:
  /api/v1/targets:
    get:
      tags: ["Targets"]
      summary: "List targets"
      description: "Browse the alive-host inventory. `q` accepts free text plus dork expressions; `sort`/`dir` order the results."
      parameters:
        - { name: program, in: query, schema: { type: string }, description: "metadata.program." }
        - { name: status, in: query, schema: { type: string }, description: "http.status_code." }
        - { name: q, in: query, schema: { type: string }, description: "Free-text (host/ip/title/tech) and/or dork expression." }
        - { name: sort, in: query, schema: { type: string, enum: [host, ip, port, status, title, date], default: date } }
        - { name: dir, in: query, schema: { type: string, enum: [asc, desc], default: desc } }
        - { name: page, in: query, schema: { type: integer, default: 1, minimum: 1 } }
        - { name: limit, in: query, schema: { type: integer, default: 50, maximum: 200 } }
      responses:
        "200":
          description: "Paginated target list."
          content:
            application/json:
              schema:
                allOf:
                  - $ref: "#/components/schemas/PageEnvelope"
                  - type: object
                    properties:
                      targets: { type: array, items: { $ref: "#/components/schemas/Target" } }
        "401": { $ref: "#/components/responses/Unauthorized" }
  /api/v1/targets/{id}:
    get:
      tags: ["Targets"]
      summary: "Get one target"
      description: "Fetch a target by ObjectId. An invalid ObjectId yields 404."
      parameters:
        - { name: id, in: path, required: true, schema: { type: string }, description: "Mongo ObjectId string." }
      responses:
        "200": { description: "The target.", content: { application/json: { schema: { $ref: "#/components/schemas/Target" } } } }
        "401": { $ref: "#/components/responses/Unauthorized" }
        "404": { $ref: "#/components/responses/NotFound" }
components:
  schemas:
    Target:
      type: object
      description: "An alive host (raw normalized Mongo doc; extra keys allowed)."
      additionalProperties: true
      properties:
        id: { type: string, description: "Mongo ObjectId (surfaced from _id)." }
        metadata: { type: object, additionalProperties: true }
        target: { type: object, additionalProperties: true, description: "host, ip, port." }
        http: { type: object, additionalProperties: true, description: "status_code, title." }
        headers: { type: object, additionalProperties: true }
        csp: { type: object, additionalProperties: true }
        fingerprint: { type: object, additionalProperties: true }
        tech: { type: array, items: { type: string } }
```

- [x] **Step 4: Write `control_center.yaml`** (no `x-api-scope`)

Create `web/config/openapi/control_center.yaml`:
```yaml
paths:
  /api/v1/control_center/templates:
    get:
      tags: ["Control Center"]
      summary: "List templates"
      description: "All Whiterabbit command templates, ordered by name."
      responses:
        "200":
          description: "Templates."
          content: { application/json: { schema: { type: object, properties: { templates: { type: array, items: { $ref: "#/components/schemas/CcTemplate" } } }, required: [templates] } } }
        "401": { $ref: "#/components/responses/Unauthorized" }
    post:
      tags: ["Control Center"]
      summary: "Create a template"
      description: "Create a template from either structured fields or a raw `yaml` string. Returns 422 with an errors array on invalid input."
      requestBody:
        required: true
        content: { application/json: { schema: { $ref: "#/components/schemas/CcTemplateInput" } } }
      responses:
        "201": { description: "Created.", content: { application/json: { schema: { $ref: "#/components/schemas/CcTemplate" } } } }
        "422": { $ref: "#/components/responses/CcUnprocessable" }
        "401": { $ref: "#/components/responses/Unauthorized" }
  /api/v1/control_center/templates/{id}:
    parameters:
      - { name: id, in: path, required: true, schema: { type: integer } }
    get:
      tags: ["Control Center"]
      summary: "Get one template"
      description: "Fetch a template by id."
      responses:
        "200": { description: "The template.", content: { application/json: { schema: { $ref: "#/components/schemas/CcTemplate" } } } }
        "401": { $ref: "#/components/responses/Unauthorized" }
        "404": { $ref: "#/components/responses/NotFound" }
    patch:
      tags: ["Control Center"]
      summary: "Update a template"
      description: "Update from structured fields or a raw `yaml` string."
      requestBody: { required: true, content: { application/json: { schema: { $ref: "#/components/schemas/CcTemplateInput" } } } }
      responses:
        "200": { description: "Updated.", content: { application/json: { schema: { $ref: "#/components/schemas/CcTemplate" } } } }
        "422": { $ref: "#/components/responses/CcUnprocessable" }
        "401": { $ref: "#/components/responses/Unauthorized" }
        "404": { $ref: "#/components/responses/NotFound" }
    put:
      tags: ["Control Center"]
      summary: "Update a template (PUT alias)"
      description: "Identical to PATCH."
      requestBody: { required: true, content: { application/json: { schema: { $ref: "#/components/schemas/CcTemplateInput" } } } }
      responses:
        "200": { description: "Updated.", content: { application/json: { schema: { $ref: "#/components/schemas/CcTemplate" } } } }
        "422": { $ref: "#/components/responses/CcUnprocessable" }
        "401": { $ref: "#/components/responses/Unauthorized" }
        "404": { $ref: "#/components/responses/NotFound" }
    delete:
      tags: ["Control Center"]
      summary: "Delete a template"
      description: "Remove a template. Returns 204 on success."
      responses:
        "204": { description: "Deleted." }
        "401": { $ref: "#/components/responses/Unauthorized" }
        "404": { $ref: "#/components/responses/NotFound" }
  /api/v1/control_center/templates/validate:
    post:
      tags: ["Control Center"]
      summary: "Validate structured template fields"
      description: "Dry-run a structured template; returns validity, errors, and the rendered YAML without persisting."
      requestBody: { required: true, content: { application/json: { schema: { $ref: "#/components/schemas/CcTemplateInput" } } } }
      responses:
        "200":
          description: "Validation result."
          content: { application/json: { schema: { type: object, properties: { valid: { type: boolean }, errors: { type: array, items: { type: string } }, yaml: { type: string } }, required: [valid, errors, yaml] } } }
        "401": { $ref: "#/components/responses/Unauthorized" }
  /api/v1/control_center/templates/validate_yaml:
    post:
      tags: ["Control Center"]
      summary: "Validate a raw YAML template"
      description: "Parse a raw `yaml` string; returns validity, errors, and the parsed attributes without persisting."
      requestBody: { required: true, content: { application/json: { schema: { type: object, properties: { yaml: { type: string } }, required: [yaml] } } } }
      responses:
        "200":
          description: "Validation result."
          content: { application/json: { schema: { type: object, properties: { valid: { type: boolean }, errors: { type: array, items: { type: string } }, template: { type: [object, "null"], additionalProperties: true } }, required: [valid, errors] } } }
        "401": { $ref: "#/components/responses/Unauthorized" }
  /api/v1/control_center/jobs:
    get:
      tags: ["Control Center"]
      summary: "List jobs"
      description: "Recent Whiterabbit jobs, newest first."
      parameters:
        - { name: limit, in: query, schema: { type: integer, default: 50, maximum: 200 } }
      responses:
        "200":
          description: "Jobs."
          content: { application/json: { schema: { type: object, properties: { jobs: { type: array, items: { $ref: "#/components/schemas/CcJob" } } }, required: [jobs] } } }
        "401": { $ref: "#/components/responses/Unauthorized" }
    post:
      tags: ["Control Center"]
      summary: "Submit a job"
      description: "Run a template (by name) against a target list via Whiterabbit. Returns 422 if the template's commands fail validation."
      requestBody:
        required: true
        content:
          application/json:
            schema:
              type: object
              properties:
                template: { type: string, description: "Template name." }
                targets: { type: array, items: { type: string } }
                queue_name: { type: string, default: "test" }
                target_chunk: { type: integer }
                delay: { type: integer }
              required: [template]
      responses:
        "201": { description: "Job recorded and submitted.", content: { application/json: { schema: { $ref: "#/components/schemas/CcJob" } } } }
        "422": { $ref: "#/components/responses/CcUnprocessable" }
        "401": { $ref: "#/components/responses/Unauthorized" }
        "404": { $ref: "#/components/responses/NotFound" }
  /api/v1/control_center/health:
    get:
      tags: ["Control Center"]
      summary: "Backend health"
      description: "RabbitMQ and Mongo reachability for the Whiterabbit backend."
      responses:
        "200":
          description: "Health snapshot."
          content:
            application/json:
              schema:
                type: object
                properties:
                  rabbitmq: { type: object, properties: { ok: { type: boolean }, detail: { type: string } } }
                  mongo: { type: object, properties: { ok: { type: boolean }, detail: { type: string } } }
        "401": { $ref: "#/components/responses/Unauthorized" }
  /api/v1/control_center/stats:
    get:
      tags: ["Control Center"]
      summary: "Job dashboard stats"
      description: "Aggregate job counts, success rate, top templates, per-queue and last-30-days daily counts."
      responses:
        "200":
          description: "Stats payload."
          content:
            application/json:
              schema:
                type: object
                properties:
                  totals: { type: object, additionalProperties: true }
                  by_status: { type: array, items: { type: object, additionalProperties: true } }
                  top_templates: { type: array, items: { type: object, additionalProperties: true } }
                  by_queue: { type: array, items: { type: object, additionalProperties: true } }
                  daily: { type: array, items: { type: object, additionalProperties: true } }
        "401": { $ref: "#/components/responses/Unauthorized" }
components:
  # NOTE: no `responses:` block here — CcUnprocessable is defined in base.yaml
  # (the service merges only paths + schemas from fragments). This fragment
  # only $ref's it.
  schemas:
    CcTemplate:
      type: object
      properties:
        id: { type: integer }
        name: { type: string }
        kind: { type: string }
        tags: { type: array, items: { type: string } }
        description: { type: [string, "null"] }
        output: { type: [string, "null"] }
        commands: { type: array, items: { type: object, additionalProperties: true } }
        target: { type: [object, "null"], additionalProperties: true }
        created_by: { type: [string, "null"] }
        yaml: { type: string, description: "Rendered YAML form." }
        created_at: { type: string, format: date-time }
        updated_at: { type: string, format: date-time }
    CcTemplateInput:
      type: object
      description: "Either structured fields OR a raw `yaml` string (yaml wins if both are present)."
      properties:
        yaml: { type: string }
        name: { type: string }
        kind: { type: string }
        description: { type: string }
        output: { type: string }
        tags: { type: array, items: { type: string } }
        commands: { type: array, items: { type: object, properties: { command: { type: string }, operator: { type: string }, args: { type: array, items: { type: string } } } } }
        target: { type: object, properties: { type: { type: string }, separator: { type: string }, output: { type: string } } }
    CcJob:
      type: object
      properties:
        id: { type: integer }
        template_name: { type: string }
        queue_name: { type: string }
        target_count: { type: integer }
        status: { type: string, enum: [pending, succeeded, failed] }
        exit_status: { type: [integer, "null"] }
        stdout: { type: [string, "null"] }
        stderr: { type: [string, "null"] }
        created_by: { type: [string, "null"] }
        created_at: { type: string, format: date-time }
```

- [x] **Step 5: Write `runner.yaml`** (no `x-api-scope`; runner-token auth)

Create `web/config/openapi/runner.yaml`:
```yaml
paths:
  /api/v1/runner/jobs/claim:
    post:
      tags: ["Runner"]
      summary: "Claim the next runner job"
      description: |
        Machine endpoint for the Whiterabbit runner. Authenticates with the
        **runner** machine token (not a user API token) via
        `Authorization: Bearer <runner-token>`. Returns 204 when no job is
        queued, otherwise the claimed job.
      responses:
        "200":
          description: "The claimed job."
          content: { application/json: { schema: { type: object, properties: { id: { type: integer }, kind: { type: string }, command: { type: string } }, required: [id, kind, command] } } }
        "204": { description: "No job available." }
        "401": { $ref: "#/components/responses/Unauthorized" }
  /api/v1/runner/jobs/{id}/result:
    post:
      tags: ["Runner"]
      summary: "Report a runner job result"
      description: "Report the outcome of a claimed, running job. Authenticates with the runner machine token. Returns 404 if the job is not owned by the runner or not running."
      parameters:
        - { name: id, in: path, required: true, schema: { type: integer } }
      requestBody:
        required: true
        content:
          application/json:
            schema:
              type: object
              properties:
                exit_status: { type: integer }
                stdout: { type: string }
                stderr: { type: string }
                error: { type: [string, "null"] }
                duration_ms: { type: integer }
                output_truncated: { type: boolean }
      responses:
        "200": { description: "Recorded.", content: { application/json: { schema: { type: object, properties: { ok: { type: boolean } }, required: [ok] } } } }
        "401": { $ref: "#/components/responses/Unauthorized" }
        "404": { $ref: "#/components/responses/NotFound" }
```

- [x] **Step 6: Verify every fragment parses and merges without duplicate-key errors**

Run from `web/`:
```bash
bin/rails runner 'd = ApiDocs::Spec.document(scopes: nil); puts d["paths"].keys.sort; puts "paths=#{d["paths"].size}"'
```
Expected: all `/api/v1/...` paths from the reference table printed (30 path keys total including `/api/v1/openapi`), no exception. If a `DuplicateKeyError` fires, two fragments declared the same schema name — rename one (schema names are global across fragments).

- [x] **Step 7: Commit**

```bash
cd /home/claude/workspace
git add web/config/openapi/vulnerabilities.yaml web/config/openapi/programs.yaml web/config/openapi/targets.yaml web/config/openapi/control_center.yaml web/config/openapi/runner.yaml
git -c user.name='Claude' -c user.email='noreply@anthropic.com' commit -m "Add OpenAPI fragments for the vulnerabilities, programs, targets, control center and runner modules"
```

---

### Task 5: Drift + shape tests (anti-drift gate)

**Files:**
- Test: `web/test/services/api_docs/coverage_test.rb`

**Interfaces:**
- Consumes: `Rails.application.routes` and `ApiDocs::Spec.document(scopes: nil)`.
- Produces: a bidirectional route↔spec guarantee — the test fails on any undocumented `/api/v1` route or any documented-but-nonexistent path, and asserts every operation has `summary` + `tags`.

- [x] **Step 1: Write the drift + shape test**

Create `web/test/services/api_docs/coverage_test.rb`:
```ruby
require "test_helper"

class ApiDocs::CoverageTest < ActiveSupport::TestCase
  # Verb+path pairs actually served under /api/v1, normalized to OpenAPI style
  # (:id -> {id}, no format suffix). Excludes HEAD/OPTIONS and the bare :verb.
  def route_pairs
    Rails.application.routes.routes.filter_map do |route|
      path = route.path.spec.to_s.sub(/\(\.:format\)$/, "")
      next unless path.start_with?("/api/v1")

      verb = route.verb.to_s.downcase
      next if verb.blank? || %w[head options].include?(verb)

      normalized = path.gsub(/:([a-z_]+)/) { "{#{Regexp.last_match(1)}}" }
      [verb, normalized]
    end.uniq
  end

  # Verb+path pairs the spec documents.
  def spec_pairs
    doc = ApiDocs::Spec.document(scopes: nil)
    doc["paths"].flat_map do |path, ops|
      ops.keys.select { |k| %w[get post put patch delete].include?(k) }.map { |verb| [verb, path] }
    end
  end

  test "every /api/v1 route is documented" do
    undocumented = route_pairs - spec_pairs
    assert_empty undocumented, "Routes missing from the OpenAPI spec: #{undocumented.inspect}"
  end

  test "every documented path exists as a route" do
    phantom = spec_pairs - route_pairs
    assert_empty phantom, "Spec documents nonexistent routes: #{phantom.inspect}"
  end

  test "every operation has a summary and tags" do
    doc = ApiDocs::Spec.document(scopes: nil)
    doc["paths"].each do |path, ops|
      ops.each do |verb, op|
        next unless %w[get post put patch delete].include?(verb)

        assert op["summary"].present?, "#{verb.upcase} #{path} is missing a summary"
        assert op["tags"].present?, "#{verb.upcase} #{path} is missing tags"
      end
    end
  end

  test "x-api-scope is present exactly where the controller declares one and matches it" do
    scoped = { "/api/v1/cves" => "cves", "/api/v1/vulnerabilities" => "vulnerabilities" }
    doc = ApiDocs::Spec.document(scopes: nil)
    scoped.each do |path, expected|
      op = doc.dig("paths", path, "get")
      assert_equal expected, op["x-api-scope"], "#{path} GET should declare x-api-scope #{expected}"
    end
    # A no-scope controller's operation must omit x-api-scope.
    assert_nil doc.dig("paths", "/api/v1/targets", "get", "x-api-scope")
    assert_nil doc.dig("paths", "/api/v1/programs/changes", "get", "x-api-scope")
  end
end
```

- [x] **Step 2: Run the test**

Run from `web/`:
```bash
bin/rails test test/services/api_docs/coverage_test.rb
```
Expected: PASS (4 tests). If "Routes missing from the OpenAPI spec" fails, the listed pair exists as a route but has no matching fragment entry — add it to the correct fragment. If "Spec documents nonexistent routes" fails, a fragment path/verb has no route — fix the fragment (usual cause: a typo in the path or a verb the controller doesn't serve). The `openapi#show` route must resolve to `["get", "/api/v1/openapi"]` and is documented — if it flags as undocumented, add a minimal `openapi` operation to `base.yaml`'s `paths` (see note below).

- [x] **Step 3: If `/api/v1/openapi` flags as undocumented, self-document it in base.yaml**

Add to `web/config/openapi/base.yaml` a top-level `paths:` block (if not already present) documenting the endpoint itself:
```yaml
paths:
  /api/v1/openapi:
    get:
      tags: ["Meta"]
      summary: "This OpenAPI document"
      description: "Returns this document, filtered to the calling token's scopes. Session and wildcard-token callers receive every module."
      responses:
        "200": { description: "The OpenAPI 3.1 document.", content: { application/json: { schema: { type: object, additionalProperties: true } } } }
        "401": { $ref: "#/components/responses/Unauthorized" }
```
Re-run Step 2; expected PASS.

- [x] **Step 4: Commit**

```bash
cd /home/claude/workspace
git add web/test/services/api_docs/coverage_test.rb web/config/openapi/base.yaml
git -c user.name='Claude' -c user.email='noreply@anthropic.com' commit -m "Add the OpenAPI drift and shape tests guarding route/spec coverage both ways"
```

---

### Task 6: `/docs` web department — Swagger UI page, monochrome skin, sidebar link, icon

**Files:**
- Create: `web/app/controllers/docs_controller.rb`
- Create: `web/app/views/docs/index.html.erb`
- Create: `web/app/assets/stylesheets/swagger_ui_skin.css`
- Modify: `web/config/routes.rb` (web routes, outside the api namespace)
- Modify: `web/app/helpers/navigation_helper.rb` (`utility_nav_items`)
- Modify: `web/app/helpers/icon_helper.rb` (add `code-bracket`)
- Test: `web/test/integration/docs_test.rb`
- Test: `web/test/helpers/icon_helper_test.rb` (only if it enumerates icons)

**Interfaces:**
- Consumes: Propshaft assets `swagger-ui.css` / `swagger-ui-bundle.js` (Task 1), `swagger_ui_skin.css`, and `GET /api/v1/openapi.json` (Task 3).
- Produces: `GET /docs` (`docs#index`), route helper `docs_path`, sidebar "API Docs" entry.

- [x] **Step 1: Write the failing docs page + sidebar test**

Create `web/test/integration/docs_test.rb`:
```ruby
require "test_helper"

class DocsTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }

  test "requires a session" do
    get "/docs"
    assert_redirected_to new_session_path
  end

  test "renders the Swagger UI mount node and vendored assets" do
    sign_in_as(@user)
    get "/docs"
    assert_response :success
    assert_select "#swagger-ui", count: 1
    assert_select "link[href*=?]", "swagger-ui"
    assert_select "link[href*=?]", "swagger_ui_skin"
    assert_select "script[src*=?]", "swagger-ui-bundle"
  end

  test "the sidebar shows the API Docs link" do
    sign_in_as(@user)
    get root_path
    assert_select "a[href=?]", docs_path
  end

  test "the docs entry lights up as active on /docs" do
    sign_in_as(@user)
    get "/docs"
    assert_select "a[href=?][aria-current=page]", docs_path
  end
end
```

- [x] **Step 1b: Run it to verify it fails**

Run from `web/`:
```bash
bin/rails test test/integration/docs_test.rb
```
Expected: FAIL — no route matches `/docs` / `docs_path` undefined.

- [x] **Step 2: Add the web route**

In `web/config/routes.rb`, in the web (non-API) routes area — next to the other department roots like `settings`/`help` — add:
```ruby
  # API documentation (Swagger UI) — a utility department behind session auth.
  get "docs", to: "docs#index"
```
Confirm placement outside the `namespace :api` block. Verify the `new_session_path` helper name used in the test matches this app's login route:
```bash
bin/rails runner 'puts Rails.application.routes.url_helpers.respond_to?(:new_session_path)'
```
Expected: `true`. If it prints `false`, open `config/routes.rb`, find the login route (the one `ApplicationController`'s auth redirects to), and update the test's `assert_redirected_to` target to that helper.

- [x] **Step 3: Add the controller**

Create `web/app/controllers/docs_controller.rb`:
```ruby
# Renders the interactive API documentation (Swagger UI) booted against the
# machine OpenAPI endpoint. Plain web controller behind the standard session
# auth (ApplicationController), so the page uses the operator's cookie for
# try-it-out on GET endpoints.
class DocsController < ApplicationController
  def index
  end
end
```

- [x] **Step 4: Add the `code-bracket` heroicon**

In `web/app/helpers/icon_helper.rb`, add a new entry to the `HEROICON_PATHS` hash (place it after the `"question-mark-circle"` entry, keeping the hash's comma syntax valid — add a trailing comma to the preceding entry's closing `]` if needed):
```ruby
    "code-bracket" => [
      "M17.25 6.75L22.5 12l-5.25 5.25m-10.5 0L1.5 12l5.25-5.25m7.5-3l-4.5 16.5"
    ],
```

- [x] **Step 5: Add the sidebar entry**

In `web/app/helpers/navigation_helper.rb`, add to the `utility_nav_items` array (before Settings/Help or after — place it first so it sits above Settings):
```ruby
      { label: "API Docs", path: docs_path, controllers: %w[docs], icon: "code-bracket" },
```
Resulting `utility_nav_items`:
```ruby
  def utility_nav_items
    [
      { label: "API Docs", path: docs_path, controllers: %w[docs], icon: "code-bracket" },
      { label: "Settings", path: settings_path, controllers: %w[settings], icon: "cog" },
      { label: "Help", path: help_path, controllers: %w[help], icon: "question-mark-circle" }
    ]
  end
```

- [x] **Step 6: Write the monochrome skin**

Create `web/app/assets/stylesheets/swagger_ui_skin.css`:
```css
/* Monochrome skin for Swagger UI on /docs — recolors Swagger's greens/blues to
   Hunter's black-and-white language and adds dark-mode support. Loaded AFTER
   swagger-ui.css so these rules win. Scoped to #swagger-ui so nothing leaks. */
#swagger-ui .topbar { display: none; }
#swagger-ui .info { margin: 1.5rem 0; }

/* Neutralize method colors to grayscale bands. */
#swagger-ui .opblock.opblock-get   { border-color: #52525b; background: rgba(82,82,91,0.04); }
#swagger-ui .opblock.opblock-post  { border-color: #27272a; background: rgba(39,39,42,0.05); }
#swagger-ui .opblock.opblock-put,
#swagger-ui .opblock.opblock-patch { border-color: #3f3f46; background: rgba(63,63,70,0.05); }
#swagger-ui .opblock.opblock-delete{ border-color: #71717a; background: rgba(113,113,122,0.05); }
#swagger-ui .opblock .opblock-summary-method { background: #27272a; }

#swagger-ui .btn.authorize,
#swagger-ui .btn.execute {
  background: #18181b; color: #fafafa; border-color: #18181b;
}
#swagger-ui .btn.authorize svg { fill: #fafafa; }
#swagger-ui a, #swagger-ui .opblock-tag { color: #18181b; }

/* Slim scrollbars on Swagger's overflow containers. */
#swagger-ui .opblock-body pre.microlight,
#swagger-ui .responses-inner,
#swagger-ui .model-box {
  scrollbar-width: thin;
  scrollbar-color: rgb(113 113 122 / 0.4) transparent;
}

/* Dark theme: honor both prefers-color-scheme and the app's .dark toggle. */
@media (prefers-color-scheme: dark) {
  html:not(.light) #swagger-ui, html:not(.light) #swagger-ui .scheme-container {
    background: #0b0d0e; color: #e4e4e7;
  }
  html:not(.light) #swagger-ui .opblock .opblock-summary-description,
  html:not(.light) #swagger-ui .info .title,
  html:not(.light) #swagger-ui a,
  html:not(.light) #swagger-ui .opblock-tag,
  html:not(.light) #swagger-ui table thead tr th,
  html:not(.light) #swagger-ui .parameter__name,
  html:not(.light) #swagger-ui .response-col_status { color: #e4e4e7; }
  html:not(.light) #swagger-ui .btn.authorize,
  html:not(.light) #swagger-ui .btn.execute { background: #e4e4e7; color: #0b0d0e; border-color: #e4e4e7; }
}
html.dark #swagger-ui, html.dark #swagger-ui .scheme-container { background: #0b0d0e; color: #e4e4e7; }
html.dark #swagger-ui .info .title,
html.dark #swagger-ui a,
html.dark #swagger-ui .opblock-tag,
html.dark #swagger-ui table thead tr th,
html.dark #swagger-ui .parameter__name,
html.dark #swagger-ui .response-col_status,
html.dark #swagger-ui .opblock .opblock-summary-description { color: #e4e4e7; }
html.dark #swagger-ui .btn.authorize,
html.dark #swagger-ui .btn.execute { background: #e4e4e7; color: #0b0d0e; border-color: #e4e4e7; }
```

- [x] **Step 7: Write the docs view**

Create `web/app/views/docs/index.html.erb`:
```erb
<% content_for :title, "API Docs" %>
<%# Full-bleed: Swagger UI manages its own width and internal scrolling. %>
<% content_for :container, "w-full px-4 py-6" %>

<% content_for :head do %>
  <%= stylesheet_link_tag "swagger-ui" %>
  <%= stylesheet_link_tag "swagger_ui_skin" %>
<% end %>

<div id="swagger-ui" class="slim-scroll"></div>

<%= javascript_include_tag "swagger-ui-bundle" %>
<script>
  (function () {
    function boot() {
      if (!window.SwaggerUIBundle || !document.getElementById("swagger-ui")) return;
      window.SwaggerUIBundle({
        url: "<%= api_v1_openapi_path(format: :json) %>",
        dom_id: "#swagger-ui",
        docExpansion: "list",
        defaultModelsExpandDepth: 0,
        tagsSorter: "alpha",
        operationsSorter: "alpha",
        withCredentials: true
      });
    }
    document.addEventListener("turbo:load", boot);
    document.addEventListener("DOMContentLoaded", boot);
  })();
</script>
```
Note: `withCredentials: true` sends the session cookie so GET try-it-out works. `api_v1_openapi_path` is the helper for the Task 3 route (`get "openapi"` inside `namespace :api { namespace :v1 }` → `api_v1_openapi_path`). Verify the helper name:
```bash
cd web && bin/rails runner 'puts app.api_v1_openapi_path(format: :json)'
```
Expected: `/api/v1/openapi.json`. If the helper differs, use the printed name in the view.

- [x] **Step 8: Run the docs test to verify it passes**

Run from `web/`:
```bash
bin/rails test test/integration/docs_test.rb
```
Expected: PASS (4 tests). If the "requires a session" redirect target is wrong, correct it per Step 2's check. If `stylesheet_link_tag "swagger-ui"` raises `Propshaft::MissingAssetError`, re-check Task 1's Propshaft registration.

- [x] **Step 9: Update the icon helper test if it enumerates icons**

Check whether `web/test/helpers/icon_helper_test.rb` asserts a fixed icon set (it was modified in the working tree). Run:
```bash
cd web && bin/rails test test/helpers/icon_helper_test.rb
```
- If it PASSES, no change needed — skip to Step 10.
- If it FAILS because it checks an exact icon count/list, add an assertion for the new icon. Read the file, then add a test mirroring its existing style, e.g.:
```ruby
  test "renders the code-bracket icon path" do
    assert_includes IconHelper::HEROICON_PATHS.keys, "code-bracket"
    assert_match(/<svg/, icon("code-bracket"))
  end
```

- [x] **Step 10: Run the sidebar shell test (existing) to confirm no regression**

Run from `web/`:
```bash
bin/rails test test/integration/sidebar_shell_test.rb
```
Expected: PASS. The API Docs link is additive; existing assertions still hold.

- [x] **Step 11: Commit**

```bash
cd /home/claude/workspace
git add web/app/controllers/docs_controller.rb web/app/views/docs web/app/assets/stylesheets/swagger_ui_skin.css web/config/routes.rb web/app/helpers/navigation_helper.rb web/app/helpers/icon_helper.rb web/test/integration/docs_test.rb web/test/helpers/icon_helper_test.rb
git -c user.name='Claude' -c user.email='noreply@anthropic.com' commit -m "Add the /docs Swagger UI department with a monochrome skin and a sidebar link"
```

---

### Task 7: Full-suite verification

**Files:** none (verification only).

- [x] **Step 1: Run the whole test suite**

Run from `web/`:
```bash
bin/rails test
```
Expected: all tests pass (0 failures, 0 errors). Pay attention to the new files: `test/services/api_docs/spec_test.rb`, `test/services/api_docs/coverage_test.rb`, `test/integration/api/v1/openapi_test.rb`, `test/integration/docs_test.rb`.

- [x] **Step 2: Manually confirm the merged document is valid OpenAPI**

Run from `web/`:
```bash
bin/rails runner 'require "json"; d = ApiDocs::Spec.document(scopes: nil); puts JSON.generate(d).length; puts d["info"]["title"]; puts d["paths"].size'
```
Expected: a non-trivial byte length, `Hunter API`, and the full path count. No exceptions.

- [x] **Step 3: If any test fails, fix and re-run before considering the plan complete.** Do not commit a broken suite.

---

## Self-Review

**Spec coverage:**
- Piece 1 (per-module YAML fragments incl. base.yaml) → Tasks 2, 3, 4. Every fragment listed in the spec is authored (`cves`, `vulnerabilities`, `programs`, `targets`, `control_center`, `runner`), each operation carries `tags`/`summary`/`description`/`x-api-scope` per Task 4's rule and the shape test.
- Piece 2 (`ApiDocs::Spec` merge + scope filter, glob discovery, dev reload, dup raise) → Task 2.
- Piece 3 (`GET /api/v1/openapi.json`, no scope declaration, scope-filtered render, route) → Task 3.
- Piece 4 (vendored Swagger UI, DocsController, `/docs` route, sidebar `utility_nav_items` entry, `code-bracket` icon, monochrome skin + dark support + slim-scroll, try-it-out reality documented in `info.description`) → Tasks 1, 6, and base.yaml's description (Task 2).
- Piece 5 (drift test both directions, shape test, service tests, controller tests, docs page test) → Tasks 2, 3, 5, 6.
- Piece 6 (content quality bar; CVE module to LLM-self-serve depth) → Task 3's `cves.yaml`.

**Placeholder scan:** No TBD/TODO/"handle edge cases"/"similar to Task N" — every code and YAML step contains full content.

**Type consistency:** Service method `document(scopes:, dir:)` is defined in Task 2 and consumed identically in Tasks 3 (`scopes: Current.api_token&.scopes`) and 5 (`scopes: nil`). `DuplicateKeyError` defined in Task 2, referenced in its own test. `$ref` targets (`#/components/responses/Unauthorized`, `InsufficientScope`, `NotFound`, `BadRequest`, `UpstreamUnavailable`, `CcUnprocessable`; `#/components/schemas/PageEnvelope`, `Error`, `Cve`, `Vulnerability`, `Target`, `ProgramChange`, `ScopeRun`, `CcTemplate`, `CcTemplateInput`, `CcJob`) are each defined: base.yaml defines the shared responses + `Error`/`PageEnvelope`; `CcUnprocessable` is defined in `control_center.yaml`; each schema is defined in its owning fragment. Route helper `api_v1_openapi_path` (Task 3) consumed in Task 6's view with a verification step. `docs_path` produced in Task 6 route, consumed in the sidebar entry and tests.

**Note on `components.responses` merge (resolved in the plan):** `ApiDocs::Spec#build` merges only `paths` and `components.schemas` from fragments, so a fragment's `components.responses` would be silently dropped. All shared responses — including `CcUnprocessable` — are therefore defined once in `base.yaml` (Task 3 Step 2) and only `$ref`'d from fragments; `control_center.yaml` carries no `components.responses` block. This is already reflected in the Task 3 and Task 4 YAML above.
```
