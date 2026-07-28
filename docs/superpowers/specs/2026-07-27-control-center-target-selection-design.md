# Control Center: select targets from Target & Sitemap pages (send-job selection API)

**Date:** 2026-07-27
**Status:** Approved (design) — pending spec review
**Modules:** Control Center (job send), Targets, Sitemap

## Problem

Sending a Control Center job today means typing targets by hand. The send dialog
on the Templates tab (`web/app/views/control_center/templates/index.html.erb`) has
a **Targets (one per line)** `<textarea>`; `control_center_templates_controller.js`
splits it on newlines into a `targets[]` array and POSTs to
`POST /api/v1/control_center/jobs`, which writes the strings to a temp
`targets.txt` and shells out to `whiterabbit standalone -target <file>`.

Hunter already knows the user's assets and crawled endpoints:

- **Targets** — the live Mongo `alive` collection, served read-only at
  `/api/v1/targets` via `Targets::MongoSource`, with search + a dork DSL
  (`host:*.example.com status:>=500 tech:nginx`). Each asset carries `host`,
  `url`, `scheme`, `port`, …
- **Sitemap** — a Postgres projection (`sitemap_targets` + `sitemap_endpoints`,
  the katana ∪ wayback crawl URLs). Web controllers only — **no `/api/v1/sitemap`
  endpoint exists yet.** Endpoints carry full `url`, `path`, `method`.

We want to **select many targets** (individually *or* "everything matching the
current filter") directly from the Target page and the Sitemap page and feed them
into a job — at a scale of **hundreds of thousands of targets**, which is common.

## Goals

- Pick targets from the Target page and the Sitemap page — individual checkboxes
  *and* "select all N matching the current filter".
- Feed the selection into the existing job send flow; keep manual textarea entry
  working (the final list is the union of both, de-duplicated).
- Scale to ~500k targets with flat memory, no client-side target shipping, no
  arbitrary cap, and without blocking an HTTP request.
- Respect module boundaries: each module owns its own collection and its own
  `/api/v1/<module>` selection API; Control Center stays the single job entrypoint.
- **Build for headless / MCP use from day one.** The JSON API must be complete and
  usable on its own — bearer-token + per-module scope, a closed descriptor schema,
  async submit-then-poll, and full OpenAPI coverage — so an MCP server can wrap it
  later with no redesign. The browser UI is one client of this API, not a
  precondition for it.

## Non-goals (YAGNI)

- Persisting / naming / reusing saved "target sets".
- Scheduling or recurring jobs.
- Any change to how Whiterabbit itself consumes the target file or fans work to
  workers (its `-target-chunk` already does per-worker chunking).
- A `/api/v1/sitemap` write surface (the read `index` is all this needs).

## Decisions (locked during brainstorming)

1. **Selection model:** checkboxes for ad-hoc picks **and** server-resolved
   "select all matching the current filter".
2. **Target value per source:** an alive asset contributes its **host**; a sitemap
   endpoint contributes its **full URL**. Fixed by source (not user-chosen).
3. **API placement:** each module exposes selection data via its own API (add the
   missing Sitemap read API alongside existing `/api/v1/targets`); a narrow
   resolver lets Control Center turn a selection descriptor into strings by calling
   each owning module's service. Control Center never touches the `alive`
   collection or the sitemap tables directly.
4. **Execution model:** a job runs as a **background (Solid Queue) job**. `create`
   writes the Job row as `queued` and returns immediately; a worker streams
   targets to the file, runs Whiterabbit, and updates the Job to
   `running`→`succeeded`/`failed`. (Solid Queue is already the configured
   ActiveJob adapter in dev + prod, with a `worker:` process in both Procfiles and
   existing jobs under `app/jobs/`.)
5. **Chunking:** rely on Whiterabbit's existing `-target-chunk`; **one Hunter Job
   per submission** (one audit record). Default `target_chunk` to a configured
   non-zero value when the field is left blank, so a huge send never becomes one
   oversized RabbitMQ message.
6. **Headless/MCP-first API:** every new/changed endpoint is bearer-accessible and
   per-module scope-gated, the `selections[]` descriptor is a closed schema, submit
   is async submit-then-poll, and all of it is documented in the OpenAPI fragments —
   so a future MCP server maps onto it 1:1 without a redesign.

## Architecture

### 1. Selection descriptor — the API contract

The browser never ships target strings; it ships a compact descriptor. Both the
preview endpoint and `jobs#create` accept a `selections[]` array. Each entry is one
of two modes:

```jsonc
// filter mode — "everything matching this search", resolved server-side
{ "source": "targets", "mode": "filter",
  "q": "host:*.example.com status:>=500",   // same query string the page's search box uses
  "exclude_ids": ["<id>", ...] }            // rows un-ticked from a select-all

// ids mode — an explicit ad-hoc pick
{ "source": "sitemap", "mode": "ids", "ids": ["<endpoint_id>", ...] }
```

- `source` ∈ `{ "targets", "sitemap" }`. Unknown source → `400 bad_request`.
- The **field is fixed by source** (targets → `host`, sitemap → endpoint `url`), so
  it is not part of the descriptor.
- `exclude_ids` supports the "select-all then untick a few" gesture without
  expanding to a large id list.
- The request may also carry the legacy literal `targets[]` (manual textarea
  lines). The final list is `union(manual targets, resolved selections)`.

### 2. Per-module resolve methods (module boundaries)

Each owning module gains a narrow, well-named method that resolves a descriptor to
target strings. **These stream from a DB cursor — they never build a giant array
in one shot** (they yield, or write directly to an IO):

- **Targets** — `Targets::MongoSource.each_host(q:, ids:, exclude_ids:) { |host| }`
  (and a matching `count_hosts(...)`). Reuses the existing `SearchParser` + dork
  filter for `q`; `ids`/`exclude_ids` map to `_id` `$in`/`$nin`. Yields
  `target.host`. Reads swallow `Mongo::Error` per house rule (empty on failure).
- **Sitemap** — `Sitemap::EndpointResolver.each_url(q:, ids:, exclude_ids:) { |url| }`
  (+ `count_urls(...)`), backed by scopes on `Sitemap::Endpoint`
  (`active`, filter parsing consistent with the sitemap web filters). Yields
  `endpoint.url`. Uses `find_each` so PG paging stays bounded.

The value semantics (host vs url) live in the module that owns the data.

### 3. `ControlCenter::TargetSelection` — the orchestrator

A thin service in `web/app/services/control_center/target_selection.rb`. It owns
**only** orchestration — dispatch, union, dedup, streaming — and never queries a
data store directly:

- `count(selections, manual_targets)` → an exact-ish total for the preview. Sums
  each source's DB `count()` (host and URL values don't collide across sources, so
  the union is effectively additive) plus the manual line count. Cheap; no
  materialization.
- `stream(selections, manual_targets) { |target| }` → yields every resolved target
  string exactly once. Dedup via a `Set` (host and url strings; ~500k short
  strings is tens of MB, acceptable and bounded — no cap). Dispatches each
  descriptor to the matching module's `each_*` method.

### 4. New Sitemap read API

Mirror the Vulnerabilities/Targets triplet so the Sitemap page is selectable like
the Target page:

- `Api::V1::Sitemap::EndpointsController < Api::V1::BaseController`
  (`web/app/controllers/api/v1/sitemap/endpoints_controller.rb`).
  - `index` — paginated (`pagination_page`, `clamped_limit`), filterable by the
    same query the sitemap web page uses; returns
    `{ endpoints: [{ id, url, path, method, status_code, ... }], page, limit, total }`.
  - Read failures → empty result (reads never 502 here).
- Route: a `namespace :sitemap` sibling under `namespace :api { namespace :v1 }`:
  ```ruby
  namespace :sitemap do
    resources :endpoints, only: %i[index]
  end
  ```
- **Auth / scope:** declares `api_scope :sitemap`, so it works with the browser
  cookie session **and** with a least-privilege bearer token carrying the
  `sitemap` scope — independently mintable and revocable for a future MCP. (The
  OpenAPI fragment basename `sitemap.yaml` == this scope slug, so a `sitemap`-scoped
  token downloads exactly this endpoint.) For symmetry and least-privilege MCP
  tokens, `Api::V1::TargetsController` also gains `api_scope :targets` (it declares
  none today; adding it is backward-compatible for cookie sessions and for `*`
  tokens, and lets an MCP hold a narrow `targets,sitemap,control_center` token).

### 5. Control Center endpoints

- **New** `POST /api/v1/control_center/jobs/resolve_targets` — a **preview**. Takes
  `selections[]` (+ optional `targets[]`), returns
  `{ count, truncated: false, sample: [<=50 strings] }`. Uses
  `TargetSelection.count` and a small sample — **never returns the full list** (so
  a 500k selection previews instantly with no payload blow-up). Powers the live
  "N targets" summary in the send dialog.
- **Extend** `POST /api/v1/control_center/jobs#create` — accept `selections[]`
  alongside today's literal `targets[]`. It **no longer runs Whiterabbit inline**:
  1. Re-validate the template (`TemplateValidator`) — unchanged, closes the
     save-then-run TOCTOU.
  2. Persist the descriptor + manual targets + queue/chunk/delay onto a new
     `ControlCenter::Job` row with `status: "queued"`, `target_count: nil`
     (unknown until resolved), and the template snapshot.
  3. `ControlCenter::SubmitJob.perform_later(job.id)` and return
     `201 { job }` immediately (the body carries `id` + `status: "queued"`).

The jobs controller declares `api_scope :control_center` (its sibling
`TemplatesController` already does), so all four job actions — `index`, `show`,
`resolve_targets`, `create` — are usable by a `control_center`-scoped bearer token,
not only the cookie UI.

**Async submit-then-poll (the MCP-shaped flow).** Because submit is asynchronous,
the API is deliberately a two-call contract a headless client can drive:
`POST …/jobs` → `201 { id, status: "queued" }`, then poll
`GET …/jobs/:id` until `status` is `succeeded`/`failed`, reading
`exit_status`/`stdout`/`stderr` there. `create` accepts an optional
client-supplied idempotency key (persisted on the Job, unique per user) so a
retried submit returns the existing Job instead of double-sending — cheap
insurance for network-flaky MCP callers.

### 6. Background execution — `ControlCenter::SubmitJob`

`web/app/jobs/control_center/submit_job.rb` (ActiveJob, Solid Queue), mirroring the
existing `app/jobs/{sitemap,cves}` jobs:

1. Load the Job, set `status: "running"`.
2. Open the temp `targets.txt` and **stream** `TargetSelection.stream(...)` into it
   line-by-line, counting as it writes. Store the count back on the Job
   (`target_count`).
3. Resolve `target_chunk`: use the submitted value, or a configured default
   (`CONTROL_CENTER_DEFAULT_TARGET_CHUNK`) when blank/`0`, so a large send fans out
   to many worker messages instead of one giant one. *(Exact Whiterabbit
   `-target-chunk` semantics — including what `0` means — verified against the
   binary during implementation.)*
4. Call `ControlCenter::Standalone.submit(...)` exactly as today (renders template
   to an ephemeral cmdscript dir, invokes the hardened `WhiterabbitCommand`
   wrapper), then finalize the Job (`succeeded`/`failed` + captured
   `stdout`/`stderr`/`exit_status`), and delete the temp dir in an `ensure`.

`Standalone.submit` is refactored so the caller can pass a **path to an
already-written target file** (built by streaming) instead of an in-memory
`targets` array — that is the one change that lets it scale. Its
job-timeout/output-clip behavior is unchanged, but the timeout now bounds a
background worker, not a web request.

`ControlCenter::Job::STATUSES` becomes
`%w[queued running succeeded failed pending]` — add `queued` (the new initial
state) and `running`; keep `succeeded`/`failed`; and retain `pending` in the list
so any historical rows still validate. New submissions start `queued`, never
`pending`. A migration is **not** needed (status is a free-text string column with
an inclusion validation) — only the validation list changes.

### 7. UI changes

- **Target page** (`web/app/views/targets/`): a checkbox column + a header
  "select all on page" + a toolbar **"Select all N matching filter"** toggle and a
  **Send to job** button. A `targets_selection_controller.js` Stimulus controller
  tracks either an explicit id set (ids mode) or "all matching current `q`, minus
  `exclude_ids`" (filter mode). **Send to job** builds the descriptor and hands it
  off (below).
- **Sitemap page** (`web/app/views/sitemap/`): the same selection affordance on the
  endpoint list, producing a `sitemap` descriptor of endpoint `url`s.
- **Cross-page handoff:** **Send to job** stores the descriptor in
  `sessionStorage` and navigates to Control Center → Templates. The templates
  controller, on connect, reads and clears it, opens the send dialog, and calls
  `resolve_targets` to show **"N targets selected"** (with the small sample). The
  descriptor is small even for a 500k filter selection (it's a query string, not
  the strings).
- **Send dialog:** gains the "N targets" summary and keeps the existing
  textarea; final submit posts `selections[]` + manual `targets[]` + queue / chunk
  / delay. After a `201`, it links to the Jobs tab (the job is `queued`, not yet
  finished).
- **Jobs tab:** already lists + polls; it now shows `queued`/`running` states and
  reaches `succeeded`/`failed` on refresh (no new polling machinery required beyond
  reflecting the two new statuses in the badge map).

## Data flow (end to end)

1. User filters/selects on the Target or Sitemap page → **Send to job** → descriptor
   in `sessionStorage` → navigate to Control Center.
2. Send dialog opens, calls `resolve_targets` → shows the count.
3. User picks template + queue, submits → `create` writes a `queued` Job and
   returns immediately; UI links to Jobs.
4. `SubmitJob` runs: `running` → stream resolved targets to `targets.txt` (record
   count) → `Standalone.submit` (with default-applied `-target-chunk`) →
   `succeeded`/`failed` with captured output.
5. Whiterabbit publishes chunked messages to RabbitMQ; the worker fleet executes.

## API usability & MCP-readiness

The whole surface is designed so a future MCP server (or any headless client) wraps
it with no redesign. Concretely:

- **UI-independent contract.** The API is complete on its own; the browser's
  `sessionStorage` "Send to job" handoff is a UI convenience, not part of the
  contract. A headless client drives the full flow over JSON + bearer token:
  1. discover/select — `GET /api/v1/targets` and `GET /api/v1/sitemap/endpoints`
     (both paginated + filterable via the same `q` dork syntax),
  2. build a `selections[]` descriptor (a filter `q`, or explicit `ids`),
  3. preview — `POST /api/v1/control_center/jobs/resolve_targets` → `{ count, sample }`,
  4. submit — `POST /api/v1/control_center/jobs` → `201 { id, status }`,
  5. poll — `GET /api/v1/control_center/jobs/:id` to completion.
- **Closed descriptor schema = MCP tool input schema.** `selections[]` is a closed,
  documented JSON schema (fixed `source` enum, `mode` enum, typed fields — no
  free-form/generic "run anything" shape). It is published as an OpenAPI
  `components/schemas` entry and drops straight in as an MCP tool's `inputSchema`.
  This also satisfies the AGENTS.md "dedicated closed schema / no generic tool"
  rule.
- **Least-privilege scopes.** Per-module `api_scope` (`targets`, `sitemap`,
  `control_center`) lets an operator mint a narrow token
  (`SCOPES=targets,sitemap,control_center`) for the MCP identity — no wildcard.
  Each capability stays independently revocable.
- **Self-describing.** New endpoints ship as OpenAPI fragments
  (`config/openapi/sitemap.yaml`, additions to `config/openapi/control_center.yaml`
  and `config/openapi/targets.yaml`). Because the served document is auto-filtered
  to the token's scopes, an OpenAPI-derived MCP sees exactly the tools its token
  allows. `/docs` (Swagger UI) documents them for humans in the same pass.
- **Stable envelopes + documented errors.** Responses reuse the house shapes
  (`{ targets: […], page, limit, total }`, `{ error: "<code>" }`) and the existing
  error codes (`400 bad_request`, `401 unauthorized`, `403 insufficient_scope`,
  `404 not_found`, `422`, `502 upstream_unavailable`), so a client needs no
  bespoke parsing.

### Governance note for the eventual MCP

This spec builds the **API**, not the MCP. When the MCP is actually added, its
tools split by risk and the effectful one is gated:

- **Read/preview tools** (list targets, list endpoints, `resolve_targets` preview,
  poll job status) are non-effectful — safe, low-risk MCP tools.
- **The submit tool** (`create`) is an **execution action**. Per the CLAUDE.md
  "Assistant capability change rule", wrapping it in an MCP requires an approved
  threat-model delta, a dedicated closed schema (already satisfied by the
  descriptor), dedicated authorization (the `control_center` scope), metadata-only
  audit coverage (the `Job` row already records author/time/snapshot/counts), and
  an explicit human-approval design for the effectful submit — before that tool
  ships. Designing the API now does not itself add an Assistant capability; it just
  makes the later, separately-reviewed MCP a thin, safe wrapper.

## Error handling

- Unknown `source` / malformed descriptor → `400 bad_request`.
- Template missing → `404 not_found`; template validation failure →
  `422 unprocessable_entity` (unchanged).
- Mongo **read** failures during resolution → that source contributes nothing
  (house rule); the job still runs with whatever resolved. Sitemap PG read errors
  likewise degrade to empty rather than 502 on this read path.
- Whiterabbit failure → Job `failed` + captured stderr (unchanged), now surfaced
  asynchronously on the Jobs tab.
- No hard target cap. Memory is bounded by streaming + a dedup `Set`; if the dedup
  Set itself is ever a concern at extreme scale, the fallback (not taken now) is an
  on-disk sort/uniq — noted, not built.

## Security / authorization

- The CLAUDE.md "Assistant capability change rule" is scoped to the **Assistant**
  subsystem and does **not** gate this Control Center feature. No new
  Assistant context type, tool, or provider feature is introduced.
- New surfaces stay within the existing module-API conventions: same-origin cookie
  auth + CSRF for the browser UI, **and** bearer-token access gated by per-module
  scopes (`sitemap`, `control_center`, plus a newly-declared `targets`) — no
  wildcard, each independently revocable. Effectful `create` over a cookie session
  still requires a CSRF token; over a bearer token it requires the
  `control_center` scope.
- The job audit trail is preserved and improved: every submission still writes one
  `ControlCenter::Job` with author, template snapshot, queue, resolved
  `target_count`, chunk, exit status, and clipped output.

## Testing

- **`ControlCenter::TargetSelection`** unit — filter mode, ids mode, `exclude_ids`,
  union + dedup across both sources, manual-targets union, streaming yields each
  value once; `count` sums per-source counts + manual lines. Stub the module
  resolve methods (no live Mongo/PG).
- **`Targets::MongoSource.each_host` / `count_hosts`** — filter + ids + exclude, host
  extraction, dedup, `Mongo::Error` → empty. Double the collection (`stub_methods`).
- **`Sitemap::EndpointResolver.each_url` / `count_urls`** — filter + ids + exclude,
  url extraction, `find_each` paging. Fixtures/records, no live Mongo.
- **`Api::V1::Sitemap::EndpointsController`** integration — stub the service;
  pagination envelope; empty on read failure; **bearer-token scope enforcement** —
  a `sitemap`-scoped token passes, a token lacking it → `403 insufficient_scope`,
  and a cookie session is unaffected. Same scope assertions added for the
  newly-scoped `targets` and for the `control_center` job actions.
- **OpenAPI** (`openapi_test.rb`) — the new `sitemap.yaml` fragment loads and merges;
  the descriptor schema resolves; a `sitemap`-scoped token's document contains the
  endpoints index and excludes other modules (scope-filtering still holds).
- **`Api::V1::ControlCenter::JobsController`** integration — `resolve_targets`
  returns count + sample (not the full list); `create` writes a `queued` Job and
  enqueues `SubmitJob` (assert enqueued, no inline Whiterabbit); malformed
  descriptor → 400; template-missing → 404; validation-fail → 422; a repeated
  `idempotency_key` returns the existing Job without a second enqueue.
- **`ControlCenter::SubmitJob`** unit — running→succeeded/failed transitions,
  `target_count` recorded from the streamed write, default chunk applied when
  blank, temp dir cleaned in `ensure`, Whiterabbit failure → `failed` + stderr.
  Stub `Standalone`.
- **`ControlCenter::Standalone`** — accepts a pre-written target-file path; existing
  render/flag/timeout behavior intact.
- **JS** (manual, no harness): select-all → untick → correct descriptor;
  cross-page handoff repopulates the dialog and shows the count; submit links to a
  `queued` job that reaches `succeeded` on the Jobs tab.

## Files touched

**New**
- `web/app/services/control_center/target_selection.rb` — orchestrator (count / stream).
- `web/app/services/sitemap/endpoint_resolver.rb` — `each_url` / `count_urls`.
- `web/app/jobs/control_center/submit_job.rb` — async submission.
- `web/app/controllers/api/v1/sitemap/endpoints_controller.rb` — sitemap read API.
- `web/app/javascript/controllers/targets_selection_controller.js` — selection state
  (shared by the Target and Sitemap pages).
- A migration adding the optional `idempotency_key` column (+ unique index scoped to
  author) on `control_center_jobs`. *(The `STATUSES` change needs no migration —
  status is a validated string column.)*
- Tests for each of the above.

**Changed**
- `web/app/services/targets/mongo_source.rb` — add `each_host` / `count_hosts`.
- `web/app/controllers/api/v1/targets_controller.rb` — declare `api_scope :targets`.
- `web/app/controllers/api/v1/control_center/jobs_controller.rb` — declare
  `api_scope :control_center`; add `resolve_targets`; `create` writes a `queued`
  Job (+ optional idempotency key) and enqueues `SubmitJob` (no inline run).
- `web/app/services/control_center/standalone.rb` — accept a pre-written target-file
  path (stream-friendly) instead of only an in-memory array.
- `web/app/models/control_center/job.rb` — `STATUSES` gains `queued`, `running`;
  optional unique `idempotency_key` (scoped to author).
- `web/config/routes.rb` — `namespace :sitemap { resources :endpoints, only: [:index] }`
  under `api/v1`; `resolve_targets` collection route on control_center jobs.
- `web/config/openapi/sitemap.yaml` — **new** fragment (endpoints index; basename ==
  the `sitemap` scope slug).
- `web/config/openapi/control_center.yaml` — document `resolve_targets`, the extended
  `create` (`selections[]`), and the `TargetSelection` descriptor schema under
  `components/schemas`.
- `web/config/openapi/targets.yaml` — note the newly-scoped access (`targets` scope).
- `web/app/views/targets/…`, `web/app/views/sitemap/…`,
  `web/app/views/control_center/templates/index.html.erb` — selection UI,
  "Send to job", dialog "N targets" summary.
- `web/app/javascript/controllers/control_center_templates_controller.js` — read the
  handed-off descriptor, call `resolve_targets`, post `selections[]`.
- `docker-compose*.yaml` / env docs — `CONTROL_CENTER_DEFAULT_TARGET_CHUNK` (and note
  the Solid Queue `worker:` process must be running for jobs to execute).
