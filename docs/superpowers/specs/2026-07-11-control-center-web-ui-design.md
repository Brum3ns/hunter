# Control Center Web UI — Design Spec

> Web "department" for the Control Center module. Consumes the already-built
> Control Center JSON API (`Api::V1::ControlCenter::*`: templates CRUD + validate,
> jobs submit + history, health) and adds a local RabbitMQ so a submitted job can
> be seen landing on a channel.

**Date:** 2026-07-11
**Status:** Approved (design), pending implementation plan.
**Prior art:** Programs / Vulnerabilities departments; `Department` concern;
`_department_tabs`. API design: `docs/superpowers/specs/2026-07-10-hunter-control-center-whiterabbit-api-design.md`.

## Goal

A Control Center page that (1) manages Whiterabbit command templates, (2) submits
jobs and shows their history/output, and (3) reports RabbitMQ + Mongo health — all
by consuming the existing API, structured so tabs and panels are trivially
rearranged as the module grows.

## Non-goals

- No new API endpoints, services, or models — the UI is a pure consumer.
- No Workers tab (the binary can't list workers without running a job; deferred
  in the API spec).
- No JS unit tests (repo has no JS harness).

## Architecture

Mirror the Programs/Vulnerabilities department pattern exactly.

- **Routes:** remove `get "control_center", to: "control_center#index"`; add a web
  `namespace :control_center` block (sibling to `namespace :programs`):
  ```ruby
  namespace :control_center do
    get "/",     to: "templates#index", as: :root
    get "/jobs", to: "jobs#index",      as: :jobs
  end
  ```
- **Base controller:** `ControlCenter::BaseController < ApplicationController`,
  `include Department`, declaring:
  ```ruby
  TABS = [
    { name: "Templates", path: :control_center_root_path },
    { name: "Jobs",      path: :control_center_jobs_path },
  ].freeze
  ```
  Reordering/adding a tab is a one-line change. Web controllers
  `ControlCenter::TemplatesController` / `ControlCenter::JobsController` coexist
  with the `ControlCenter::` models/services (open modules); the API stays under
  the separate `Api::V1::ControlCenter::` namespace.
- **Remove** the old `ControlCenterController` and `app/views/control_center/index.html.erb`.
- **Sidebar:** repoint the Control Center nav item from the `control_center` path
  to `control_center_root_path` (and its `controllers:` match to the new
  namespace).

## Components

Each tab is an isolated thin server shell + exactly one Stimulus controller that
talks to exactly one API endpoint. Views only render; no business logic. Rows are
built with `createElement` + `textContent` so API-supplied strings can never
inject HTML (matches `programs_monitor_controller.js`).

### 1. Templates tab — `control_center/templates/index.html.erb`
- Shell: page header + health badge, an (initially empty) templates table, a
  "New template" button, and a hidden editor panel + a hidden "Send job" dialog.
- `control_center_templates_controller.js`:
  - **List** `GET /api/v1/control_center/templates` → rows: name, kind, tags,
    a one-line command summary (e.g. `httpx | nuclei`), Edit / Send / Delete.
  - **Create/Edit** — form fields: `name`, `kind` (cmdscript|workflow),
    `description`, `output`, `tags` (comma input), and repeatable command rows
    `{ command, args, operator }`. **Live dry-run validation**: on change, debounce
    → `POST …/templates/validate` → show inline errors; Save is enabled only when
    valid. Save → `POST` (create) / `PATCH` (update). On 422, render
    `detail` messages.
  - **Delete** → `DELETE …/templates/:id`, with a confirm.
  - **Send ▶** (per row) → opens the send dialog: `targets` (textarea, one per
    line), `queue_name` (default `test`), `target_chunk`, `delay` → `POST …/jobs`
    → show returned `status` + `stdout`/`stderr` inline; offer a link to the Jobs
    tab.

### 2. Jobs tab — `control_center/jobs/index.html.erb`
- Shell: page header + health badge, a jobs history table, a hidden detail panel.
- `control_center_jobs_controller.js`:
  - **List** `GET /api/v1/control_center/jobs` → rows: template_name, queue_name,
    target_count, status badge, created_at. Newest first (API already orders).
  - **Detail** — click a row → `GET …/jobs/:id` → panel with exit_status,
    stdout, stderr (monospace, scrollable).
  - Submit is synchronous server-side (the API runs the binary inline and returns
    a finalized job), so no polling — a manual/refresh-on-return reload suffices.

### 3. Health badge — `control_center/_health.html.erb`
- Rendered in both tab headers. `control_center_health_controller.js` polls
  `GET /api/v1/control_center/health` (~15s) and colors two dots — RabbitMQ and
  Mongo — from `{ ok:, detail: }`; `detail` shown as a tooltip/title.

### Shared JS helper — `apiFetch`
A small module (`app/javascript/lib/api_fetch.js` or similar) wrapping `fetch`
with JSON headers and the `X-CSRF-Token` from the `<meta name="csrf-token">` tag
for non-GET requests (the API's cookie path is CSRF-protected). Every Control
Center controller uses it so CSRF handling is identical and in one place.

## Design language

Inherits the monochrome zinc/black Tailwind + dark-mode tables and the existing
underline tab style (`_department_tabs`). The only semantic color is functional
status: health dots and job-status badges use emerald (ok/succeeded) / rose
(down/failed) / zinc (pending) — precedented by the monitor controller's
`emerald-500` live dot. Everything else stays monochrome. Heroicons via the
existing `heroicon` helper.

## Data flow & auth

Browser (Stimulus `fetch`, signed session cookie) → `Api::V1::ControlCenter::*`
→ services (`Standalone`, `TemplateValidator`, …) → Postgres + the `whiterabbit`
binary → RabbitMQ. GET reads need no CSRF; POST/PATCH/DELETE send `X-CSRF-Token`
via `apiFetch`.

## Dummy RabbitMQ (verification)

Add a broker to `docker-compose.yaml` so a submitted job visibly lands on a
channel:

- Service `rabbitmq` using `rabbitmq:3-management`:
  - `RABBITMQ_DEFAULT_USER: ${RABBITMQ_USERNAME:-hunter}`,
    `RABBITMQ_DEFAULT_PASS: ${RABBITMQ_PASSWORD:-hunter}` (fed from the existing
    Control Center compose env; the binary reads `RABBITMQ_*`, already wired).
  - Ports `127.0.0.1:5672:5672` (AMQP) and `127.0.0.1:15672:15672` (management UI).
  - Healthcheck: `rabbitmq-diagnostics -q ping`.
- `web` service gains `depends_on: rabbitmq: { condition: service_healthy }`.
- Default `RABBITMQ_HOST` is already `rabbitmq` in compose; ensure
  `RABBITMQ_USERNAME`/`RABBITMQ_PASSWORD` have non-empty defaults in `.env.example`
  so the broker and the binary share credentials out of the box.

**Verification path:** submit a job from the Templates tab → the Jobs tab shows
`succeeded`; the health badge's RabbitMQ dot is green; the management UI at
`http://localhost:15672` shows the message on the target queue.

## Testing

Web department integration tests, per `test/integration/programs/tabs_test.rb`:

- `GET /control_center` and `/control_center/jobs` require auth (redirect when
  signed out).
- Signed in: 200, render the Templates/Jobs tabs, and include the expected
  `data-controller` wiring attributes and API URL values (so the shells are
  correctly wired even though hydration is client-side).
- No live API calls in these tests — they assert the shell/markup only.

## Adaptability

- Tabs are data (`TABS`) — add/remove/reorder in one line.
- Each tab = independent shell + controller + one endpoint; zero cross-tab
  coupling.
- Command editor, send dialog, and health badge are drop-in partials,
  restructurable without touching the tables.
- A future "Workers" or "Overview" tab is one `TABS` line + one shell + one
  controller + (if needed) one API endpoint.

## File inventory (new/changed)

- `web/config/routes.rb` — swap stub route for `namespace :control_center` web block.
- `web/app/controllers/control_center/base_controller.rb` — new (`Department` + `TABS`).
- `web/app/controllers/control_center/templates_controller.rb` — new (`index`).
- `web/app/controllers/control_center/jobs_controller.rb` — new (`index`).
- Remove `web/app/controllers/control_center_controller.rb` and
  `web/app/views/control_center/index.html.erb`.
- `web/app/views/control_center/templates/index.html.erb` — new shell.
- `web/app/views/control_center/jobs/index.html.erb` — new shell.
- `web/app/views/control_center/_health.html.erb` — new partial.
- `web/app/javascript/controllers/control_center_templates_controller.js` — new.
- `web/app/javascript/controllers/control_center_jobs_controller.js` — new.
- `web/app/javascript/controllers/control_center_health_controller.js` — new.
- `web/app/javascript/lib/api_fetch.js` — new shared helper (pin in
  `web/config/importmap.rb` if not covered by an existing `pin_all_from`).
- `web/app/views/layouts/_sidebar.html.erb` (or the nav helper) — repoint CC link.
- `docker-compose.yaml` — add `rabbitmq` service + `web` dependency.
- `.env.example` — non-empty default RabbitMQ credentials.
- `web/test/integration/control_center/tabs_test.rb` — new department tests.
