# Hunter Runner — Isolated curl Execution Subsystem

**Date:** 2026-07-01
**Status:** Design approved (pending written-spec review)

## Goal

Let a user run a vulnerability's `curl` proof-of-concept from the vuln drawer.
The command executes inside a dedicated, hardened **runner** container (never on
the Rails host), and its output streams back into the drawer. The runner pulls
work from Rails over an authenticated HTTP channel and is **structurally limited
to `curl` jobs** — it cannot see or execute any other (future) job type.

## Background

Hunter is a multi-module bug-bounty dashboard (Rails 8 in `web/`, Postgres +
Mongo, per-module `/api/v1/<module>` APIs, `ApiToken` bearer auth). The vuln
module already renders a `curl` command in the detail drawer
(`app/views/vulnerabilities/details/_code_block.html.erb`). This subsystem adds
safe execution of that command. Future work will add more job kinds (e.g.
`nuclei`, `nmap`); the design must keep the untrusted curl runner blind to them.

## Non-goals

- No container-per-job / docker-in-docker. One long-lived hardened runner
  executes jobs as subprocesses.
- No arbitrary shell execution. Only `curl` with an http/https target.
- No real-time WebSocket transport. Browser updates via polling; Rails↔runner
  via runner-initiated HTTP (pull). Both are swappable later without changing
  the job model.
- Not building the broader "control center" module — just the runner subsystem
  and the curl job kind.

## Architecture overview

```
Browser (drawer)            Rails (web)                     Runner container
    │  click "Run"             │                                  │
    ├─ POST /vulnerabilities/:id/runs ─────▶ create RunnerJob(queued)
    │                          │                                  │
    │  ◀── turbo_stream: mount self-polling result frame          │
    │                          │                                  │
    │  poll GET .../runs/:job_id (every ~1.5s until terminal)     │
    │                          │  ◀── POST /api/v1/runner/jobs/claim (bearer)
    │                          │        (returns oldest queued job
    │                          │         WHERE kind IN runner.kinds)
    │                          │                                  ├─ validate + exec curl
    │                          │                                  │   (argv, timeout, caps)
    │                          │  ◀── POST /api/v1/runner/jobs/:id/result ─┤
    │  ◀── frame renders stdout/stderr/exit/duration, stops       │
```

**Isolation model.** The runner container *is* the sandbox: non-root,
`cap_drop: ALL`, `no-new-privileges`, read-only root FS + `tmpfs /tmp`,
`mem_limit`, `pids_limit`, **no published ports** (outbound-only). Each curl runs
as an `Open3` subprocess with a hard timeout and output caps. Jobs share the
container; this is acceptable because the box holds no secrets beyond its own
scoped token, never accepts inbound connections, and never runs a shell.

## Components

### 1. `RunnerJob` (Postgres) — the single source of truth

Table `runner_jobs`:

| column           | type      | notes                                            |
|------------------|-----------|--------------------------------------------------|
| `id`             | uuid (pk) | avoids guessable sequential ids in URLs          |
| `kind`           | string    | allowlist: currently only `"curl"`               |
| `command`        | text      | the raw curl string, copied from Mongo at enqueue|
| `vulnerability_id`| string   | Mongo oid, ties result back to the drawer        |
| `status`         | string    | `queued` / `running` / `succeeded` / `failed`    |
| `exit_status`    | integer   | curl process exit code (nullable)                |
| `stdout`         | text      | truncated to `CURL_MAX_OUTPUT` bytes             |
| `stderr`         | text      | truncated                                        |
| `output_truncated`| boolean  | true if stdout/stderr was clipped                |
| `error`          | string    | validation/timeout/transport failure reason      |
| `requested_by_id`| bigint fk | the human `User` who clicked Run                 |
| `runner_id`      | bigint fk | the `Runner` that claimed it (nullable until claimed)|
| `duration_ms`    | integer   | reported by the runner                           |
| `claimed_at`     | datetime  |                                                  |
| `started_at`     | datetime  |                                                  |
| `finished_at`    | datetime  |                                                  |
| timestamps       |           |                                                  |

- `kind` validated against `RunnerJob::KINDS = %w[curl]`. Adding a kind is a
  one-line change here.
- **State machine:** `queued → running → (succeeded | failed)`. Terminal states
  never transition. `failed` is reachable directly from `queued` (enqueue-time
  validation failure) without ever being claimed.
- **Atomic claim (scoped):**
  ```sql
  UPDATE runner_jobs SET status='running', runner_id=:rid, claimed_at=now(), started_at=now()
  WHERE id = (
    SELECT id FROM runner_jobs
    WHERE status='queued' AND kind = ANY(:kinds)
    ORDER BY created_at
    FOR UPDATE SKIP LOCKED
    LIMIT 1
  )
  RETURNING *;
  ```
  `FOR UPDATE SKIP LOCKED` means concurrent runners never double-claim. The
  `kind = ANY(:kinds)` filter is the **structural scoping guarantee** — a curl
  runner's query can only ever match curl rows.
- **Staleness reaper:** a job `running` longer than `RUNNER_JOB_TTL` (e.g. 2×
  `CURL_MAX_TIME`, default 90s) is marked `failed "runner timed out"`. Enforced
  lazily on read (in `RunsController#show`) and by a `runner:reap` rake task, so
  no background scheduler is required for MVP.

### 2. `Runner` (Postgres) — scoped machine identity

Runners are **not users.** Table `runners`:

| column        | type          | notes                                  |
|---------------|---------------|----------------------------------------|
| `name`        | string uniq   | e.g. `"curl-runner"`                    |
| `token_digest`| string uniq   | SHA-256 of the raw token (raw shown once)|
| `kinds`       | string array  | allowlist of job kinds, e.g. `["curl"]`|
| `last_seen_at`| datetime      | touched on each authenticated request  |
| timestamps    |               |                                        |

- Mirrors `ApiToken`'s digest-only storage. `Runner.authenticate(raw)` returns
  the runner or nil and touches `last_seen_at`.
- `Runner.generate(name:, kinds:)` mints `[record, raw_token]`.
- Minted via rake task: `bin/rails runner:create NAME=curl-runner KINDS=curl`
  (prints the raw token once). Multiple kinds: `KINDS=curl,nuclei`.

### 3. Runner API — `Api::V1::Runner::JobsController < Api::V1::BaseController`

Bearer-only, authenticated against **`Runner`** (not `ApiToken`). The base
controller's `authenticate_api!` is overridden here to require a runner token and
set `Current.runner`; **user/API tokens are rejected**, and runner tokens are
rejected by the normal user endpoints (they are not `ApiToken`s, so
`ApiToken.authenticate` never matches them).

- `POST /api/v1/runner/jobs/claim`
  - Runs the atomic scoped claim with `Current.runner.kinds`.
  - `200 {id, kind, command}` on success, `204` when no matching queued job.
- `POST /api/v1/runner/jobs/:id/result`
  - Body: `{exit_status, stdout, stderr, error, duration_ms, output_truncated}`.
  - **Ownership check:** `404` unless the job exists, is `running`, and
    `job.runner_id == Current.runner.id`. This plus the scoped claim means a curl
    runner can neither observe nor mutate a non-curl job.
  - Records terminal state (`succeeded` when `error` blank and `exit_status==0`,
    else `failed`), truncates stored output defensively, sets `finished_at`.
  - `200 {ok: true}`.

Routes:
```ruby
namespace :api do
  namespace :v1 do
    resources :vulnerabilities, only: %i[index show create update destroy]
    namespace :runner do
      post "jobs/claim",      to: "jobs#claim"
      post "jobs/:id/result", to: "jobs#result"
    end
  end
end
```

### 4. Web enqueue + result — `Vulnerabilities::RunsController`

Session-authenticated (web department). Routes (add inside the existing
`namespace :vulnerabilities`, keeping the catch-all `get "/:id"` **last**):
```ruby
namespace :vulnerabilities do
  get   "/",            to: "overview#index", as: :root
  patch "/:id/status",  to: "statuses#update", as: :status
  post  "/:id/runs",    to: "runs#create",     as: :runs
  get   "/:id/runs/:job_id", to: "runs#show",  as: :run
  get   "/:id",         to: "details#show",    as: :detail
end
```

- `#create`: loads the vuln via `Vulnerabilities::MongoSource.find(id)`
  (`404` if missing), reads `poc.curl` (`422` if absent). Validates the command
  with `Runner::CurlCommand.validate` (defense in depth). Creates a
  `RunnerJob(kind: "curl", command:, vulnerability_id:, requested_by: Current.user)`
  — `queued` if valid, or immediately `failed` with the validation error if not.
  Responds with a Turbo Stream that replaces the PoC run region with a
  self-polling result frame.
- `#show`: renders the job's current state for the polling frame. Applies the
  staleness reaper on read. While non-terminal, the rendered frame includes the
  `poller` controller so it reloads; on terminal state it renders the output and
  omits the poller (polling stops).

**UI.** A "Run" button is added to the Proof of Concept section of
`app/views/vulnerabilities/details/_panel.html.erb`, next to the curl
`code_block`. It is a `button_to`/`form_with` POST to `vulnerabilities_runs_path`
targeting a `turbo_frame` (`runner_run_<vuln_id>`). The result is rendered with
the **existing** `_code_block.html.erb` (so stdout/stderr get the syntax
highlighting, slim scrollbars, and fit-window toggle already built), plus a small
status header (badge: queued/running/succeeded/failed, exit code, duration).

**Polling controller** (`app/javascript/controllers/poller_controller.js`):
reloads its host `turbo-frame` on an interval (`data-poller-interval-value`,
default 1500ms) and stops when the frame no longer carries the controller (i.e.
terminal state). Uses `frame.reload()` / `frame.src` reassignment. Cleans up its
timer on `disconnect`.

### 5. Safe execution — `Runner::CurlCommand`

The security-critical unit. Pure Ruby, no Rails, so the identical file lives in
both `web/app/services/runner/curl_command.rb` (enqueue-time validation) and
`runner/curl_command.rb` (execution-time gate). Deliberate duplication =
defense in depth; the file is small and its tests pin the behavior in both
places.

**`validate(command) -> [ok, argv_or_reason]`:**
1. `argv = Shellwords.split(command)`; reject if empty, if it contains NUL or a
   raw newline, or if arg count / total length exceeds caps.
2. `File.basename(argv[0])` must equal `"curl"`.
3. Every argument that looks like a URL (contains `://`, or follows `--url`, or
   is the bare positional target) must start with `http://` or `https://`.
   Reject any other scheme (`file://`, `dict://`, `gopher://`, `scp://`, …).
   Require at least one http/https URL present.
4. **Denylist flags** (reject if present): `-o` `--output` `-O` `--remote-name`
   `--output-dir` `-T` `--upload-file` `-K` `--config` `-D` `--dump-header`
   `-c` `--cookie-jar` `--trace` `--trace-ascii`. Reject `-d/--data*` and
   `-F/--form` values that reference a file (`@…`). (These are the flags that
   let curl write the filesystem or read local files.)
5. Return `[true, argv]` or `[false, reason]`.

**`execute(command) -> Result`** (runner side only):
1. `ok, argv = validate(command)`; if not ok, return failed Result with the
   reason — **never exec.**
2. Inject/clamp safety flags into argv: ensure `--max-time <= CURL_MAX_TIME`,
   `--connect-timeout`, `-sS`, `--max-filesize <CURL_MAX_OUTPUT>`.
3. `Open3.capture3(*argv)` (argv array → **no shell**, no injection surface),
   wrapped in a `Timeout`/`--max-time` guard.
4. Truncate stdout/stderr to `CURL_MAX_OUTPUT`, set `output_truncated`.
5. Return `{exit_status, stdout, stderr, error, duration_ms, output_truncated}`.

### 6. Runner container + agent

`runner/Dockerfile`: `FROM ubuntu:24.04`, install `curl` + `ruby` (stdlib only —
`net/http`, `json`, `open3`, `shellwords`, `timeout`), copy `agent.rb` +
`curl_command.rb`, run as an unprivileged user.

`runner/agent.rb` (the "simple script"): a plain-Ruby loop:
```
loop:
  job = POST {API}/api/v1/runner/jobs/claim  (Bearer RUNNER_TOKEN)
  if 204: sleep POLL_INTERVAL; continue
  result = Runner::CurlCommand.execute(job["command"])
  POST {API}/api/v1/runner/jobs/{job.id}/result  result
rescue transport error: log; sleep backoff
```

`docker-compose.yaml` — new hardened service (note: **no `ports:`**):
```yaml
runner:
  build: { context: ., dockerfile: runner/Dockerfile }
  env_file: [.env]
  environment:
    HUNTER_API_URL: http://web:5000
    RUNNER_TOKEN: ${RUNNER_TOKEN}
    RUNNER_POLL_INTERVAL: ${RUNNER_POLL_INTERVAL:-2}
    CURL_MAX_TIME: ${CURL_MAX_TIME:-30}
    CURL_MAX_OUTPUT: ${CURL_MAX_OUTPUT:-262144}
  depends_on:
    web: { condition: service_started }
  user: "65534:65534"
  read_only: true
  tmpfs: ["/tmp"]
  cap_drop: ["ALL"]
  security_opt: ["no-new-privileges:true"]
  mem_limit: 256m
  pids_limit: 128
  restart: unless-stopped
```
`.env.example` gains `RUNNER_TOKEN=` (+ the tuning vars).

## Security model (guarantees)

1. **No host execution.** Commands run only in the runner container.
2. **No shell.** `Open3.capture3(*argv)` with a validated argv array; the curl
   string (attacker-influenced scan data) is never interpolated into a shell.
3. **http/https only, no filesystem I/O.** Scheme allowlist + flag denylist stop
   `file://`, local reads, and disk writes. Validated at enqueue *and* execution.
4. **Job-kind confinement.** A runner only ever claims / results jobs whose
   `kind` is in its `kinds` allowlist. Scoped claim (`kind = ANY`) + ownership
   check on result. The curl runner is structurally blind to future kinds.
5. **Identity separation.** Runner tokens ≠ user tokens; neither works on the
   other's endpoints. Runner tokens are digest-only, minted out-of-band.
6. **No inbound surface.** The runner publishes no ports; it only makes outbound
   requests. Resource + output + time caps bound blast radius.

## Error handling

| Failure                          | Behavior                                            |
|----------------------------------|-----------------------------------------------------|
| Invalid/blocked curl             | Job `failed` with reason; **never executed**; shown in drawer |
| curl timeout / exceeds max-time  | Job `failed "timed out after Ns"`                   |
| Runner crash / job stuck running | Reaped to `failed "runner timed out"` after TTL     |
| Missing vuln / missing `poc.curl`| `404` / `422` at enqueue; no job created            |
| Bad/absent runner token          | `401` from runner endpoints                         |
| Result for a job you didn't claim| `404` (ownership check)                             |
| Output over cap                  | Truncated, `output_truncated=true` flagged in UI    |

## Testing strategy

- **`Runner::CurlCommand` (critical):** allows a plain `curl https://x`; rejects
  `-o`, `--output`, `-K`, `file://`/`dict://`, `-d @/etc/passwd`, non-`curl`
  argv[0], empty, NUL/newline; confirms `execute` never runs invalid input
  (stub `Open3`); confirms safety-flag injection/clamping. Same suite runs
  against both copies.
- **`RunnerJob` model:** state transitions; atomic scoped claim (a curl runner
  cannot claim a `nuclei` job — seeded and asserted invisible); staleness reaper.
- **`Runner` model:** `authenticate` hit/miss, `generate` digest-only, `kinds`.
- **Runner API integration:** claim returns oldest scoped job + `204` when none;
  claim excludes out-of-scope kinds; result updates + validation; bearer
  required; user token rejected; ownership 404.
- **`RunsController` integration (web):** unauthenticated → redirect to sign in;
  create enqueues a job + returns turbo_stream; invalid curl → job created
  `failed`; missing `poc.curl` → 422; show renders queued/running/terminal
  frames and applies the reaper. Stub `MongoSource` (no live Mongo).
- **Agent:** unit-test its exec path via `Runner::CurlCommand` (no network);
  transport loop is thin and covered by manual/Docker smoke, not unit tests.

No live runner container, live Mongo, or live network in the test suite.

## File layout

```
web/
  app/models/runner_job.rb
  app/models/runner.rb
  app/controllers/api/v1/runner/jobs_controller.rb
  app/controllers/vulnerabilities/runs_controller.rb
  app/services/runner/curl_command.rb
  app/views/vulnerabilities/runs/{create.turbo_stream.erb,show.html.erb,_result.html.erb}
  app/views/vulnerabilities/details/_panel.html.erb   (add Run button + run frame)
  app/javascript/controllers/poller_controller.js
  config/routes.rb                                     (runner API + vuln runs routes)
  db/migrate/*_create_runner_jobs.rb
  db/migrate/*_create_runners.rb
  lib/tasks/runner.rake                                (runner:create, runner:reap)
  test/{models,integration,services}/...
runner/
  Dockerfile
  agent.rb
  curl_command.rb                                      (kept in sync with web copy)
  test/curl_command_test.rb
docker-compose.yaml                                    (add hardened runner service)
.env.example                                           (RUNNER_TOKEN + tuning vars)
```

## Future extension

A new job kind (e.g. `nuclei`) = add the kind to `RunnerJob::KINDS`, a matching
executor service, and a **separate** scoped runner (`KINDS=nuclei`) with its own
container/token. The curl runner needs no change and remains structurally unable
to see or run the new kind. Transport (pull→WebSocket) and browser updates
(poll→broadcast) can each be swapped independently without touching the job
model.
