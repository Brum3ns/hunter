# Hunter Control Center module — Whiterabbit standalone API

**Date:** 2026-07-10
**Status:** Approved (design)
**Scope of this pass:** The **API layer** of a new **Control Center** module that
manages the **Whiterabbit** `standalone` job sender end to end from the web app.
Web department views beyond what the API needs are a later pass; this spec is the
API + service + model + safety layer.

## 1. Goal

Hunter's Control Center tab is a one-line stub. This work makes it a real module —
the third Hunter department after Vulnerabilities and Programs — that drives the
**Whiterabbit** Go CLI's `standalone` mode: authoring the YAML command templates
that describe work, submitting jobs (publishing them to RabbitMQ for the worker
fleet to execute), and inspecting connections/workers.

Two user decisions set the shape:
- **Full template CRUD in the web UI** — users author/edit the YAML command
  templates in-app (not just run ops-managed files on disk).
- **Job submission is in v1** — the API can actually send jobs, not only inspect.

Both push toward the high-capability path. Because a web-authored template
defines system commands the worker fleet executes, this is **remote command
execution by design**, and the safety engineering (§6) is the centre of the work,
not an afterthought.

## 2. Architecture & boundary

**Web → API → CLI**, mirroring the Programs/Scope pattern.

- The Rails **Control Center** module owns a JSON API under
  `/api/v1/control_center/...` and (later) a web department. It **never invokes a
  shell**.
- To send jobs and run inspections it shells out to the `whiterabbit` binary
  (baked into the image, located via `WHITERABBIT_BIN`, mirroring `SCOPE_BIN`)
  through a hardened `Open3.capture3(*argv)` wrapper modeled on
  `Sandbox::CurlCommand`.
- The template's `command`/`args` execute **on the RabbitMQ worker consumers, not
  in Rails**. Rails/`standalone` only *builds, signs, and publishes* the job.
  Rails is therefore the **authorization gate** that decides what gets signed
  (with the shared `CMDSCRIPT_HASH_SALT`) and enqueued — which is exactly where
  §6's controls sit.

### Whiterabbit CLI contract this module depends on

`whiterabbit standalone` flags (verified against `internal/option/option.go`):

- **Run/send:** `-run <name>`, `-folder-cmdscript <dir>`, `-folder-workflow <dir>`,
  `-target <file>`, `-target-chunk <n>`, `-queue-name <q>`, `-delay <ms>`,
  `-salt <hashsalt>`, `-db <badgerdir>`.
- **RabbitMQ:** `-host`, `-port`, `-port-http`, `-user`, `-pass`, `-token`,
  `-timeout`.
- **Inspection:** `-list` (template names), `-validate` (validate cmdscript
  folder), `-check-rabbitmq`, `-check-mongo`, `-info` (connected consumers).

cmdscript YAML schema (verified against `pkg/cmdscript/cmdscript.go`):
`name` (string, required), `tags` ([]string), `desc` (string),
`output` (string, optional), `commands` ([]{ `command` string required,
`args` ([]scalar), `operator` one of `""` `|` `&&` `||` }), optional
`target` ({ `type`, `separator`, `output` }).

## 3. Chosen approach — Postgres source-of-truth + render-to-ephemeral-dir

(Approach A of the three considered; B = mutable on-disk folder, rejected for
TOCTOU/audit; C = HTTP server inside the Go tool, rejected as off-pattern.)

1. Templates live **structured in Postgres**, validated on every write.
2. On job submit: **re-validate**, render the selected template(s) to a **fresh
   temporary `-folder-cmdscript` dir** (restrictive perms), write the target list
   to a temp file, invoke `whiterabbit standalone -run <name> -folder-cmdscript
   <tmp> -target <tmpfile> ...` via the hardened wrapper, capture the result into
   a `Job` row, then delete the temp dir in an `ensure`.

Rationale: full audit + versioning, validation at the DB boundary, no mutable
shared folder, no validate-then-run TOCTOU window, and it matches Hunter's
existing Postgres-config convention. Cost: the renderer must faithfully reproduce
Whiterabbit's YAML schema (covered by round-trip tests).

## 4. Module shape (isolation)

Everything namespaced `ControlCenter::` (web) / `Api::V1::ControlCenter::` (API),
exactly as `Vulnerabilities::` and `Programs::` are.

### Services (`app/services/control_center/`)
- **`WhiterabbitCommand`** — the argv allowlist wrapper (the `Sandbox::CurlCommand`
  analog). Fixed subcommand (`standalone`), flag allowlist, no shell, timeout,
  output caps. Single seam (`capture`) for stubbing in tests.
- **`TemplateValidator`** — structural validation (schema, required fields, valid
  operators) + the command allowlist (default-deny) + arg/metacharacter caps.
- **`TemplateRenderer`** — `ControlCenter::Template` row → Whiterabbit YAML.
- **`Standalone`** — orchestrates a submission: render → temp dir → invoke →
  capture → cleanup; and the `health` checks.

### Models (Postgres)
- **`ControlCenter::Template`** — `name` (unique), `kind` (`cmdscript` |
  `workflow`), `tags`, `desc`, `output`, `commands` (JSON: array of
  {command, args, operator}), optional `target` (JSON), timestamps, author.
  Validates through `TemplateValidator` on save.
- **`ControlCenter::Job`** — audit + status row per submission: template snapshot
  (JSON, so history survives later template edits), `queue_name`, `target_count`,
  `status` (`pending`/`succeeded`/`failed`), binary `exit_status`, captured
  `stdout`/`stderr` (clipped), `created_by`, timestamps.

### API controllers (`app/controllers/api/v1/control_center/`, all `< Api::V1::BaseController`)
- `templates` — index/show/create/update/destroy + a `validate` collection action.
- `jobs` — index/show + create (submit/send).
- `health` — show (`-check-rabbitmq` / `-check-mongo`).
- `workers` — deferred (see §5).

### Routes
A sibling block under `namespace :api { namespace :v1 { ... } }`:

```ruby
namespace :control_center do
  resources :templates, only: %i[index show create update destroy] do
    collection { post :validate }
  end
  resources :jobs, only: %i[index show create]
  resource  :health,  only: :show, controller: "health"
end
```

### Web department
Replaces the `ControlCenterController` stub with a `ControlCenter::` department
(base controller `include Department`, a `TABS` list, sidebar entry). Rich views
are a later pass; this spec delivers whatever the API endpoints need to be usable.

## 5. API surface (v1)

```
GET    /api/v1/control_center/templates            # list
POST   /api/v1/control_center/templates            # create (validate-on-write)
GET    /api/v1/control_center/templates/:id        # show
PATCH  /api/v1/control_center/templates/:id        # update (validate-on-write)
DELETE /api/v1/control_center/templates/:id        # destroy
POST   /api/v1/control_center/templates/validate   # dry-run validation
GET    /api/v1/control_center/jobs                 # submission history
POST   /api/v1/control_center/jobs                 # submit (send jobs to RabbitMQ)
GET    /api/v1/control_center/jobs/:id             # one job (status + captured output)
GET    /api/v1/control_center/health               # RabbitMQ + Mongo reachability
```

**`workers` deferred.** The binary's standalone `-info` does not return — it prints
consumer info and then falls through into an actual job run (requiring a valid
`-run` template). There is therefore no clean "list workers only" invocation in
standalone mode. A `workers` endpoint would need to call RabbitMQ's management
HTTP API directly and is deferred to a later pass.

Error envelopes reuse `Api::BaseController`'s (`401`, `403`, `400`, `404`,
`502 upstream_unavailable`). A failed binary invocation (non-zero exit, timeout)
surfaces as a `Job` with `status: "failed"` plus captured stderr, not an
uncaught 500.

## 6. Safety model (the crux)

Because the web UI defines what the worker fleet runs, defense concentrates in the
API + services:

1. **No shell, ever.** Commands are structured `command` + `args[]` (Whiterabbit
   already models args as a list). We pass **discrete argv** to the binary and
   never interpolate a user string into a shell. Operators are restricted to the
   CLI's validated set (`""`, `|`, `&&`, `||`).
2. **Command allowlist (default-deny).** A configurable allowlist of permitted
   binaries (recon tooling). An unknown `command` is rejected on save **and**
   re-checked at submit. Allowlist source: env/config, default-deny on unknown.
3. **Arg & metacharacter validation.** Reject NUL bytes and newlines; cap arg
   count and total length (mirroring `Sandbox::CurlCommand`'s `MAX_ARGS` /
   `MAX_LENGTH`); reject shell metacharacters in args except through the explicit
   `operator` field.
4. **Signing.** Rendered templates are signed with `CMDSCRIPT_HASH_SALT` — the
   mechanism the workers already use to verify a command is authentic — so only
   API-approved templates run on the fleet.
5. **Re-validate at submit**, not only at save, closing the validate-then-run
   TOCTOU window.
6. **Audit trail.** Every submission writes a `ControlCenter::Job` row: author,
   time, template snapshot, target count, queue, binary exit status, and clipped
   stdout/stderr. Secrets (`-pass`, `-token`, `-salt`) are sourced from env and
   never persisted or logged.
7. **Hardened invocation.** Fixed `standalone` subcommand, flag allowlist,
   `Timeout`-guarded `Open3.capture3`, output byte-caps, ephemeral temp dir with
   restrictive perms cleaned up in an `ensure`.

## 7. Configuration / env

- `WHITERABBIT_BIN` — path to the binary in the image (default e.g.
  `/usr/local/bin/whiterabbit`).
- `CMDSCRIPT_HASH_SALT`, `RABBITMQ_HOST/PORT/HTTP_PORT/USERNAME/PASSWORD/TOKEN` —
  passed to the binary from env, wired in docker-compose; never persisted.
- `CONTROL_CENTER_COMMAND_ALLOWLIST` — comma-separated permitted binaries
  (default-deny when unset means an empty allowlist rejects everything, so a
  sensible seeded default is provided).
- Build: the image gains a Go build stage for `whiterabbit` (like scope's
  `scope-build` stage) copying the binary into the web image; CI already builds
  the web image.

## 8. Testing

- **Controller integration** — stub the `Standalone`/`WhiterabbitCommand`
  services; no live binary or RabbitMQ. Cover auth (cookie + bearer), validation
  rejections, the submit happy path, and the failed-job path.
- **`WhiterabbitCommand` unit** — argv assembly and every rejection branch (the
  security-critical surface): flag allowlist, no-shell guarantee, caps, timeout.
- **`TemplateValidator` unit** — allowlist default-deny, operator set, arg caps,
  metacharacter rejection.
- **`TemplateRenderer` round-trip** — Postgres row → YAML parses back to an
  equivalent structure Whiterabbit accepts.
- **Model tests** — `Template` validation wiring, `Job` snapshotting.
- Uses the existing `stub_methods` helper (`test/test_helper.rb`).

## 9. Out of scope (v1)

Scheduling/recurring jobs, workflow-script chaining UI, live job-progress
streaming, and worker-fleet management beyond read-only `-info`.
