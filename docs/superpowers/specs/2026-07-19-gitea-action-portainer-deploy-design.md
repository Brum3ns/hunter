# Gitea Action + Portainer deploy — design

**Date:** 2026-07-19
**Status:** Approved, pending implementation plan

## Goal

Make the Gitea Actions workflow build and push a *working* Hunter image set to
the infra registry, and give Portainer a compose file that pulls those images.
Today the workflow exists but the `web` image build fails in CI, and there is no
production compose for Portainer to deploy.

## Problem analysis

The workflow `.gitea/workflows/build.yml` already builds and pushes two images
(`<repo>-web`, `<repo>-runner`) to `${REGISTRY_HOST}`. Findings:

- **Runner image is fine.** `runner/Dockerfile` only copies `runner/*.rb`, all
  tracked in git — a Gitea `actions/checkout` has everything it needs.
- **Web image build fails in CI.** The root `Dockerfile` builds the whiterabbit
  Go binary from `tmp/whiterabbit/`:
  ```
  COPY tmp/whiterabbit/go.mod tmp/whiterabbit/go.sum ./
  COPY tmp/whiterabbit/ ./
  ```
  But `tmp/` is gitignored, so `tmp/whiterabbit` is untracked. `actions/checkout`
  only restores tracked files, so those paths are absent in CI and the `COPY`
  fails. It works locally only because a clone happens to sit at `tmp/whiterabbit`.
- **`go install` is not a clean fix.** whiterabbit's `go.mod` declares
  `module github.com/Brum3ns/whiterabbit`, but Gitea serves the `go-import` meta
  as `10.0.1.2:3002/gadmin/whiterabbit`. `go install <gitea-path>/...` aborts on
  the module-path mismatch; `go install github.com/Brum3ns/whiterabbit/...`
  resolves to GitHub instead of Gitea (needs GitHub reachable, `GOPRIVATE`, and
  git auth, and builds GitHub's branch, not the Gitea one). Same for scope.
- **No production compose.** The only compose, `docker-compose.yaml`, is a dev
  compose that `build:`s locally. Portainer needs an `image:`-pulling compose.

whiterabbit and scope both live on the same Gitea host
(`http://10.0.1.2:3002/gadmin/{whiterabbit,scope}.git`), reachable from the CI
runner, so cloning them in the workflow is straightforward.

## Design

### 1. Workflow: clone Go sources before build

In `.gitea/workflows/build.yml`, add a step (before the docker build steps) that
clones both Go projects into the build context from the same Gitea host, reusing
the registry credentials (`gadmin` + `secrets.REGISTRY_TOKEN`) since the Gitea
web and container registry share the host in `REGISTRY_HOST`:

- `git clone --depth 1 [--branch $WHITERABBIT_REF] http://gadmin:$TOKEN@$REGISTRY_HOST/gadmin/whiterabbit.git tmp/whiterabbit`
- `git clone --depth 1 [--branch $SCOPE_REF]        http://gadmin:$TOKEN@$REGISTRY_HOST/gadmin/scope.git       tmp/scope`

Refs come from repo variables `vars.WHITERABBIT_REF` / `vars.SCOPE_REF`,
defaulting to `main`. This keeps Gitea as the source of truth and leaves the
Dockerfile's `COPY tmp/whiterabbit/` untouched — CI materializes the clone the
same way a local checkout does. The existing web and runner build/push steps are
unchanged.

**Assumption:** `secrets.REGISTRY_TOKEN` is a `gadmin` Gitea PAT valid for both
git-over-HTTP and the registry. If it is registry-scoped only, split out a
separate clone secret.

### 2. Dockerfile: add a scope build stage

Mirror the existing whiterabbit stage with a scope stage, then embed the binary:

```dockerfile
FROM golang:1.24-bookworm AS scope-build
WORKDIR /src
COPY tmp/scope/go.mod tmp/scope/go.sum ./
RUN go mod download
COPY tmp/scope/ ./
RUN CGO_ENABLED=0 GOOS=linux go build -o /out/scope ./cmd/scope
```

In the final image:

```dockerfile
COPY --from=scope-build /out/scope /usr/local/bin/scope
ENV SCOPE_BIN=/usr/local/bin/scope
```

Building from cloned source is a local build, so the go.mod module-path mismatch
is irrelevant. scope's `go.mod` targets Go 1.24, hence `golang:1.24-bookworm`
(whiterabbit stays on `golang:1.23-bookworm`). The scope binary is staged now for
the future Programs module; the app need not use it yet.

### 3. New `.dockerignore`

Keep the build context lean and predictable regardless of what sits under `tmp/`:

```
**/.git
tmp/scope/web
web/vendor/bundle
web/tmp
web/log
web/node_modules
```

`tmp/scope/web` (scope's Rails app) is excluded — only scope's Go source is
needed. This also protects context size when a full local clone is present.

### 4. New `web/Procfile.prod`

Production process set. No Tailwind watcher — CSS is precompiled at image build
via `assets:precompile` (tailwindcss-rails hooks into it).

```
web: bin/rails server -b 0.0.0.0 -p 5000
worker: bin/rails solid_queue:start
stream: bin/rails sitemap:stream
```

`worker` runs Solid Queue against the production `queue` database; `stream` runs
the Mongo→Postgres sitemap change-stream sync.

### 5. New `docker-compose.prod.yaml`

What Portainer deploys — a self-contained stack mirroring scope's prod compose,
adapted to hunter's services:

- **db** — `postgres:18-alpine`, named volume, healthcheck.
- **mongo** — `mongo:8` as single-node replica set `rs0` with the same
  self-initiating healthcheck as the dev compose (required for change streams).
- **rabbitmq** — `rabbitmq:4-management`, provisioned broker user.
- **web** — `image: ${REGISTRY_HOST}/${REGISTRY_OWNER}/${REGISTRY_REPO}-web:latest`,
  `pull_policy: always`, `restart: unless-stopped`. Env mirrors the dev web
  service but `RAILS_ENV=production`, adds `SECRET_KEY_BASE` and
  `RAILS_MASTER_KEY` (master.key is gitignored, so supplied via env),
  `RAILS_SERVE_STATIC_FILES=true`, `RAILS_LOG_TO_STDOUT=true`. Command:
  ```
  sh -c 'rm -f tmp/pids/server.pid &&
         bundle exec rails db:prepare &&
         bundle exec rails db:seed &&
         foreman start -f Procfile.prod'
  ```
  `db:prepare` creates and migrates all four production databases (primary,
  cache, queue, cable) via Rails 8 multi-db; `db:seed` is idempotent (already run
  every boot in dev) and provisions the admin user. Publishes port `5000`.
- **runner** — `image: ${REGISTRY_HOST}/${REGISTRY_OWNER}/${REGISTRY_REPO}-runner:latest`,
  `pull_policy: always`, same security hardening as the dev runner
  (`read_only`, `cap_drop: ALL`, `no-new-privileges`, non-root, mem/pids limits),
  `HUNTER_API_URL=http://web:5000`.

Image reference variables — `REGISTRY_HOST`, `REGISTRY_OWNER` (default `gadmin`),
`REGISTRY_REPO` (default `hunter`) — matching scope's prod compose naming and the
workflow's `<repo>-web`/`<repo>-runner` tags.

**Assumption:** mongo and rabbitmq are bundled for a guaranteed-working stack. If
infra provides them externally, trim those services and point `MONGO_HOST` /
`RABBITMQ_HOST` at the external hosts.

### Deploy-host prerequisites (documented, not code)

`pull_policy: always` fails silently-looking failures without these on the
**Portainer host** — the workflow only fixes the push side. Document in the prod
compose header:

1. **Insecure registry.** The registry is served over HTTP. The docker daemon on
   the Portainer host needs `{"insecure-registries": ["<REGISTRY_HOST>"]}` in
   `/etc/docker/daemon.json` (then restart docker), or the pull errors on the
   HTTPS probe. (The workflow's push side already handles this via buildkit
   `http = true` + a hand-written `~/.docker/config.json`.)
2. **Registry auth.** The host must be `docker login`'d to `REGISTRY_HOST`
   (user `gadmin` + the same PAT), or have the credential stored, to pull the
   private images.
3. **TLS reverse proxy.** `config/environments/production.rb` sets
   `force_ssl = true` and `assume_ssl = true` (and leaves `config.hosts`
   unset, so there is no host-authorization block). `assume_ssl` keeps the
   in-network runner working over `http://web:5000`, but session cookies are
   marked `secure`, so **browser login requires HTTPS**. The stack expects a
   TLS-terminating reverse proxy in front of the published `5000` port; direct
   `http://host:5000` works only for the token-based runner, not browser login.

### Runtime behavior note

`RUNNER_TOKEN` must be **empty or strong**. `db:seed` calls
`Runner.ensure_from_token!`, which raises `Runner::WeakTokenError` on a weak
token; the seed then `abort`s, breaking the `&&` command chain so `web` never
starts. Blank token = runner bootstrap skipped (feature off). Generate a strong
one with `openssl rand -base64 32`.

## Out of scope

- No CI test stage (build/push only, matching current workflow intent).
- No change to the dev `docker-compose.yaml`.
- The Programs module wiring that consumes the scope binary (staged only).

## Files touched

- `.gitea/workflows/build.yml` — modified (add clone step, ref vars)
- `Dockerfile` — modified (add scope build stage + embed)
- `.dockerignore` — new
- `web/Procfile.prod` — new
- `docker-compose.prod.yaml` — new
