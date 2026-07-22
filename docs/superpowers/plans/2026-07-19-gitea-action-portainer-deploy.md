# Gitea Action + Portainer Deploy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Gitea Actions workflow build and push working `web` + `runner` images to the infra registry, and give Portainer a compose file that pulls and runs them.

**Architecture:** The `web` image build fails in CI because it copies the whiterabbit Go source from `tmp/whiterabbit/`, which is gitignored and absent after `actions/checkout`. Fix: the workflow clones `whiterabbit` and `scope` from the same Gitea host into the build context before `docker build`; the Dockerfile gains a scope build stage; a `.dockerignore` keeps the context lean; and a new `docker-compose.prod.yaml` + `web/Procfile.prod` let Portainer pull and run the pushed images.

**Tech Stack:** Gitea Actions (GitHub-Actions-compatible), Docker buildx multi-stage builds, Go 1.23/1.24, Ruby 3.3.6 / Rails 8, foreman, PostgreSQL, MongoDB (replica set), RabbitMQ.

## Global Constraints

- **Commit author:** `Claude <noreply@anthropic.com>` (verbatim).
- **Commit messages:** a single sentence, no body.
- **Registry host:** HTTP registry at `${REGISTRY_HOST}` (default `10.0.1.2:3002`); Gitea web/git and the container registry share this host.
- **Registry/clone user:** `gadmin`; token is `secrets.REGISTRY_TOKEN` (assumed a `gadmin` Gitea PAT valid for both git-over-HTTP and the registry).
- **Image tags produced by the workflow:** `${REGISTRY_HOST}/${gitea.repository}-web` and `-runner` (i.e. `.../gadmin/hunter-web`, `.../gadmin/hunter-runner`).
- **Ruby module namespace:** `Hunter`. Rails app lives in `web/`; repo root holds `Dockerfile`, `docker-compose*.yaml`, `.gitea/`.
- **This environment has no docker/foreman/yq** — only `python3`. Local gates use python YAML/structure checks; the authoritative `docker build` / `docker compose config` / `foreman check` commands are noted per task for CI or the deploy host.

---

### Task 1: web image builds the scope binary (Dockerfile + .dockerignore)

Add a scope build stage mirroring the existing whiterabbit stage, embed the binary, and add a `.dockerignore` so the build context stays lean regardless of what sits under `tmp/`.

**Files:**
- Create: `.dockerignore`
- Modify: `Dockerfile` (add `scope-build` stage after the `whiterabbit-build` stage at lines 1-6; add scope `COPY`/`ENV` after the whiterabbit binary copy at lines 38-39)

**Interfaces:**
- Consumes: cloned Go sources present at `tmp/whiterabbit/` and `tmp/scope/` in the build context (materialized locally by dev checkout, in CI by Task 4). Both contain `go.mod`, `go.sum`, and `cmd/<name>/`.
- Produces: an image with `/usr/local/bin/whiterabbit` and `/usr/local/bin/scope`, and `SCOPE_BIN=/usr/local/bin/scope` set in the environment.

- [ ] **Step 1: Write the failing check**

Create `/home/claude/workspace/scratch_check_dockerfile.py` (temporary, deleted in Step 6):

```python
import sys, pathlib
root = pathlib.Path("/home/claude/workspace")
df = (root / "Dockerfile").read_text()
di = (root / ".dockerignore")
errs = []
if "AS scope-build" not in df:
    errs.append("Dockerfile: missing 'AS scope-build' stage")
if "go build -o /out/scope ./cmd/scope" not in df:
    errs.append("Dockerfile: missing scope go build")
if "COPY --from=scope-build /out/scope /usr/local/bin/scope" not in df:
    errs.append("Dockerfile: missing scope binary COPY")
if "ENV SCOPE_BIN=/usr/local/bin/scope" not in df:
    errs.append("Dockerfile: missing SCOPE_BIN env")
if not di.exists():
    errs.append(".dockerignore: file missing")
else:
    dit = di.read_text()
    for needle in ["**/.git", "tmp/scope/web", "web/vendor/bundle"]:
        if needle not in dit:
            errs.append(f".dockerignore: missing '{needle}'")
# context sources must exist so the COPY targets are real
for p in ["tmp/whiterabbit/go.mod", "tmp/scope/go.mod", "tmp/scope/go.sum"]:
    if not (root / p).exists():
        errs.append(f"context source missing: {p}")
if errs:
    print("FAIL"); [print(" -", e) for e in errs]; sys.exit(1)
print("PASS")
```

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 /home/claude/workspace/scratch_check_dockerfile.py`
Expected: `FAIL` listing the missing scope stage / COPY / ENV and missing `.dockerignore`.

- [ ] **Step 3: Create `.dockerignore`**

Create `/home/claude/workspace/.dockerignore`:

```
# Keep the build context lean and predictable regardless of what sits under
# tmp/. The web image only needs the Go source of whiterabbit and scope
# (go.mod/go.sum + cmd/internal/pkg), plus web/ and runner/.
**/.git

# scope's Rails app is not needed to build the scope Go binary; excluding it
# also keeps a full local scope checkout (with web/vendor/bundle) out of the
# context.
tmp/scope/web

# Never ship the host's bundle/tmp/logs/node_modules into the context.
web/vendor/bundle
web/tmp
web/log
web/node_modules
```

- [ ] **Step 4: Add the scope build stage and binary to `Dockerfile`**

After the whiterabbit stage (the `RUN ... go build -o /out/whiterabbit ./cmd/whiterabbit` line, before `FROM ruby:3.3.6-slim`), insert:

```dockerfile

FROM golang:1.24-bookworm AS scope-build
WORKDIR /src
COPY tmp/scope/go.mod tmp/scope/go.sum ./
RUN go mod download
COPY tmp/scope/ ./
RUN CGO_ENABLED=0 GOOS=linux go build -o /out/scope ./cmd/scope
```

Then, immediately after the existing two lines:

```dockerfile
COPY --from=whiterabbit-build /out/whiterabbit /usr/local/bin/whiterabbit
ENV WHITERABBIT_BIN=/usr/local/bin/whiterabbit
```

add:

```dockerfile
COPY --from=scope-build /out/scope /usr/local/bin/scope
ENV SCOPE_BIN=/usr/local/bin/scope
```

- [ ] **Step 5: Run the check to verify it passes**

Run: `python3 /home/claude/workspace/scratch_check_dockerfile.py`
Expected: `PASS`

- [ ] **Step 6: Authoritative build (where docker exists) + clean up**

On a docker-capable host (CI or dev machine with the local `tmp/whiterabbit` + `tmp/scope` clones present):

```bash
cd /home/claude/workspace
docker build -t hunter-web:plantest .
docker run --rm hunter-web:plantest sh -c 'test -x /usr/local/bin/whiterabbit && test -x /usr/local/bin/scope && echo OK'
```
Expected: build succeeds; container prints `OK`.

Then remove the temporary check:
```bash
rm /home/claude/workspace/scratch_check_dockerfile.py
```

- [ ] **Step 7: Commit**

```bash
cd /home/claude/workspace
git add Dockerfile .dockerignore
git commit -m "Build the scope binary into the web image and add a lean .dockerignore" --author="Claude <noreply@anthropic.com>"
```

---

### Task 2: workflow clones Go sources before build (.gitea/workflows/build.yml)

Add a step that clones `whiterabbit` and `scope` from Gitea into the build context before the docker build steps, with ref defaults. This is what makes Task 1's `COPY tmp/...` succeed in CI.

**Files:**
- Modify: `.gitea/workflows/build.yml` (add a clone step between the buildx setup and the registry-auth/build steps)

**Interfaces:**
- Consumes: `env.REGISTRY_HOST`, `secrets.REGISTRY_TOKEN`, optional `vars.WHITERABBIT_REF` / `vars.SCOPE_REF`.
- Produces: `tmp/whiterabbit/` and `tmp/scope/` populated in the runner workspace before `docker/build-push-action`.

- [ ] **Step 1: Write the failing check**

Create `/home/claude/workspace/scratch_check_workflow.py` (temporary, deleted in Step 5):

```python
import sys, pathlib, yaml
p = pathlib.Path("/home/claude/workspace/.gitea/workflows/build.yml")
doc = yaml.safe_load(p.read_text())
steps = doc["jobs"]["build"]["steps"]
errs = []
clone = next((s for s in steps if "run" in s and "git clone" in s["run"]), None)
if clone is None:
    errs.append("no step with 'git clone' found")
else:
    run = clone["run"]
    for needle in ["gadmin/whiterabbit.git", "gadmin/scope.git",
                   "tmp/whiterabbit", "tmp/scope", "REGISTRY_HOST"]:
        if needle not in run:
            errs.append(f"clone step missing '{needle}'")
    # clone must run before the build-push steps
    names = [s.get("name", "") for s in steps]
    idx_clone = steps.index(clone)
    idx_build = next((i for i, s in enumerate(steps)
                      if "uses" in s and "build-push-action" in s["uses"]), 10**9)
    if idx_clone > idx_build:
        errs.append("clone step must precede build-push-action")
if errs:
    print("FAIL"); [print(" -", e) for e in errs]; sys.exit(1)
print("PASS (workflow YAML valid, clone step present and ordered)")
```

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 /home/claude/workspace/scratch_check_workflow.py`
Expected: `FAIL` — `no step with 'git clone' found`.

- [ ] **Step 3: Add the clone step to `.gitea/workflows/build.yml`**

Insert this step immediately after the `docker/setup-buildx-action@v3` step and before the `Write registry auth` step:

```yaml
      - name: Fetch Go sources (whiterabbit, scope) from Gitea
        env:
          REGISTRY_HOST: ${{ env.REGISTRY_HOST }}
          CLONE_TOKEN: ${{ secrets.REGISTRY_TOKEN }}
          WHITERABBIT_REF: ${{ vars.WHITERABBIT_REF }}
          SCOPE_REF: ${{ vars.SCOPE_REF }}
        run: |
          rm -rf tmp/whiterabbit tmp/scope
          git clone --depth 1 --branch "${WHITERABBIT_REF:-main}" \
            "http://gadmin:${CLONE_TOKEN}@${REGISTRY_HOST}/gadmin/whiterabbit.git" tmp/whiterabbit
          git clone --depth 1 --branch "${SCOPE_REF:-main}" \
            "http://gadmin:${CLONE_TOKEN}@${REGISTRY_HOST}/gadmin/scope.git" tmp/scope
```

- [ ] **Step 4: Run the check to verify it passes**

Run: `python3 /home/claude/workspace/scratch_check_workflow.py`
Expected: `PASS (workflow YAML valid, clone step present and ordered)`

- [ ] **Step 5: Authoritative manual clone test (optional, needs Gitea reachable) + clean up**

On a host that can reach Gitea, confirm the clone URL/token work:
```bash
REGISTRY_HOST=10.0.1.2:3002 CLONE_TOKEN=<gadmin-pat> \
  git clone --depth 1 --branch main \
  "http://gadmin:${CLONE_TOKEN}@${REGISTRY_HOST}/gadmin/whiterabbit.git" /tmp/wr-test && echo OK && rm -rf /tmp/wr-test
```
Expected: `OK`. (If the default branch is not `main`, set repo variable `WHITERABBIT_REF`/`SCOPE_REF` in Gitea accordingly — e.g. `dev`.)

Then remove the temporary check:
```bash
rm /home/claude/workspace/scratch_check_workflow.py
```

- [ ] **Step 6: Commit**

```bash
cd /home/claude/workspace
git add .gitea/workflows/build.yml
git commit -m "Clone whiterabbit and scope from Gitea into the build context before the image build" --author="Claude <noreply@anthropic.com>"
```

---

### Task 3: production Procfile (web/Procfile.prod)

Define the production process set foreman runs inside the container. No Tailwind watcher — CSS is precompiled at image build.

**Files:**
- Create: `web/Procfile.prod`

**Interfaces:**
- Consumes: nothing (Rails tasks already exist: `solid_queue:start`, `sitemap:stream`).
- Produces: a foreman Procfile with `web`, `worker`, `stream` processes, referenced by Task 4's web command as `foreman start -f Procfile.prod`.

- [ ] **Step 1: Write the failing check**

Create `/home/claude/workspace/scratch_check_procfile.py` (temporary, deleted in Step 5):

```python
import sys, pathlib, re
p = pathlib.Path("/home/claude/workspace/web/Procfile.prod")
errs = []
if not p.exists():
    errs.append("web/Procfile.prod missing")
else:
    lines = [l for l in p.read_text().splitlines() if l.strip() and not l.strip().startswith("#")]
    names = {}
    for l in lines:
        m = re.match(r"^([a-zA-Z0-9_-]+):\s+(.+)$", l)
        if not m:
            errs.append(f"malformed Procfile line: {l!r}")
        else:
            names[m.group(1)] = m.group(2)
    for want in ["web", "worker", "stream"]:
        if want not in names:
            errs.append(f"missing process '{want}'")
    if "tailwindcss:watch" in p.read_text():
        errs.append("Procfile.prod must not run the tailwind watcher")
    if "web" in names and "-p 5000" not in names["web"]:
        errs.append("web process must bind port 5000")
if errs:
    print("FAIL"); [print(" -", e) for e in errs]; sys.exit(1)
print("PASS")
```

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 /home/claude/workspace/scratch_check_procfile.py`
Expected: `FAIL` — `web/Procfile.prod missing`.

- [ ] **Step 3: Create `web/Procfile.prod`**

```
web: bin/rails server -b 0.0.0.0 -p 5000
worker: bin/rails solid_queue:start
stream: bin/rails sitemap:stream
```

- [ ] **Step 4: Run the check to verify it passes**

Run: `python3 /home/claude/workspace/scratch_check_procfile.py`
Expected: `PASS`

- [ ] **Step 5: Authoritative lint (where foreman exists) + clean up**

On a host with foreman: `cd web && foreman check -f Procfile.prod` → expects `valid procfile detected (web, worker, stream)`.

Then remove the temporary check:
```bash
rm /home/claude/workspace/scratch_check_procfile.py
```

- [ ] **Step 6: Commit**

```bash
cd /home/claude/workspace
git add web/Procfile.prod
git commit -m "Add production Procfile running the web, worker and sitemap-stream processes" --author="Claude <noreply@anthropic.com>"
```

---

### Task 4: production compose for Portainer (docker-compose.prod.yaml)

A self-contained stack that pulls the pushed images and runs the full app. Mirrors the dev compose services (db, mongo `rs0`, rabbitmq) but `web`/`runner` pull from the registry instead of building.

**Files:**
- Create: `docker-compose.prod.yaml`

**Interfaces:**
- Consumes: the images the workflow pushes (`${REGISTRY_HOST}/${REGISTRY_OWNER}/${REGISTRY_REPO}-web:latest` and `-runner:latest`); `web/Procfile.prod` (baked into the web image via `COPY web/ ./`).
- Produces: a Portainer-deployable stack. No later task depends on it.

- [ ] **Step 1: Write the failing check**

Create `/home/claude/workspace/scratch_check_compose.py` (temporary, deleted in Step 5):

```python
import sys, pathlib, yaml
p = pathlib.Path("/home/claude/workspace/docker-compose.prod.yaml")
errs = []
if not p.exists():
    errs.append("docker-compose.prod.yaml missing")
else:
    doc = yaml.safe_load(p.read_text())
    svcs = doc.get("services", {})
    for want in ["db", "mongo", "rabbitmq", "web", "runner"]:
        if want not in svcs:
            errs.append(f"missing service '{want}'")
    for name in ["web", "runner"]:
        s = svcs.get(name, {})
        if "build" in s:
            errs.append(f"{name} must not build (prod pulls images)")
        img = s.get("image", "")
        if "REGISTRY_HOST" not in img or f"-{name}:latest" not in img:
            errs.append(f"{name}.image must reference the registry and -{name}:latest")
        if s.get("pull_policy") != "always":
            errs.append(f"{name}.pull_policy must be 'always'")
    web = svcs.get("web", {})
    envs = web.get("environment", {})
    envkeys = envs if isinstance(envs, dict) else {e.split("=",1)[0].strip("${:-} ") for e in envs}
    for want in ["RAILS_ENV", "SECRET_KEY_BASE", "RAILS_MASTER_KEY"]:
        if want not in "".join(f"{k}" for k in (envkeys.keys() if isinstance(envkeys, dict) else envkeys)):
            errs.append(f"web.environment missing {want}")
    if "foreman start -f Procfile.prod" not in str(web.get("command", "")):
        errs.append("web.command must run foreman with Procfile.prod")
    if "db:prepare" not in str(web.get("command", "")):
        errs.append("web.command must run db:prepare")
if errs:
    print("FAIL"); [print(" -", e) for e in errs]; sys.exit(1)
print("PASS (compose YAML valid, services/images/command correct)")
```

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 /home/claude/workspace/scratch_check_compose.py`
Expected: `FAIL` — `docker-compose.prod.yaml missing`.

- [ ] **Step 3: Create `docker-compose.prod.yaml`**

```yaml
# Production stack for Portainer. Pulls the images the Gitea Actions workflow
# builds and pushes; does not build anything locally.
#
# Deploy-host prerequisites (the workflow only fixes the push side):
#   1. Insecure registry — the registry is HTTP. Add to the host's
#      /etc/docker/daemon.json:  {"insecure-registries": ["10.0.1.2:3002"]}
#      then restart docker, or `pull_policy: always` fails on the HTTPS probe.
#   2. Registry auth — `docker login 10.0.1.2:3002` as gadmin (the PAT), or the
#      pull is denied.
#   3. TLS reverse proxy — production sets force_ssl + assume_ssl. The internal
#      runner works over http://web:5000, but browser login needs HTTPS (session
#      cookies are `secure`). Put a TLS-terminating proxy in front of port 5000.
#
# All values are overridable from a .env file placed next to this compose file.
services:
  db:
    image: postgres:18-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${DB_USERNAME:-postgres}
      POSTGRES_PASSWORD: ${DB_PASSWORD:-postgres}
    volumes:
      - hunter_db:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USERNAME:-postgres}"]
      interval: 5s
      timeout: 5s
      retries: 10

  # Single-node replica set rs0 — required for MongoDB change streams (the
  # sitemap sync). The healthcheck initiates the set on first boot (idempotent)
  # and only reports healthy once a primary is elected.
  mongo:
    image: mongo:8
    restart: unless-stopped
    command: ["mongod", "--replSet", "rs0", "--bind_ip_all"]
    volumes:
      - mongodb_data:/data/db
    healthcheck:
      test:
        - CMD
        - mongosh
        - --quiet
        - --eval
        - "if (!db.hello().isWritablePrimary) { try { rs.initiate({ _id: 'rs0', members: [{ _id: 0, host: 'mongo:27017' }] }) } catch (e) {} ; throw new Error('mongo rs0 not ready') }"
      interval: 10s
      timeout: 5s
      retries: 15
      start_period: 5s

  rabbitmq:
    image: rabbitmq:4-management
    restart: unless-stopped
    environment:
      RABBITMQ_DEFAULT_USER: ${RABBITMQ_USERNAME:-hunter}
      RABBITMQ_DEFAULT_PASS: ${RABBITMQ_PASSWORD:-hunter}
    volumes:
      - rabbitmq_data:/var/lib/rabbitmq
    healthcheck:
      test: ["CMD", "rabbitmq-diagnostics", "-q", "ping"]
      interval: 10s
      timeout: 5s
      retries: 10

  web:
    image: ${REGISTRY_HOST:-10.0.1.2:3002}/${REGISTRY_OWNER:-gadmin}/${REGISTRY_REPO:-hunter}-web:latest
    pull_policy: always
    restart: unless-stopped
    # db:prepare creates + loads the schema for all four production databases
    # (primary, cache, queue, cable). db:seed is idempotent (admin user + runner
    # from RUNNER_TOKEN). NOTE: RUNNER_TOKEN must be empty or strong — a weak
    # token makes the seed abort and web never starts.
    command: >
      sh -c 'rm -f tmp/pids/server.pid &&
             bundle exec rails db:prepare &&
             bundle exec rails db:seed &&
             foreman start -f Procfile.prod'
    environment:
      RAILS_ENV: production
      RAILS_SERVE_STATIC_FILES: ${RAILS_SERVE_STATIC_FILES:-true}
      RAILS_LOG_TO_STDOUT: ${RAILS_LOG_TO_STDOUT:-true}
      SECRET_KEY_BASE: ${SECRET_KEY_BASE}
      RAILS_MASTER_KEY: ${RAILS_MASTER_KEY:-}
      DB_HOST: ${DB_HOST:-db}
      DB_PORT: ${DB_PORT:-5432}
      DB_DATABASE: ${DB_DATABASE:-hunter_production}
      DB_USERNAME: ${DB_USERNAME:-postgres}
      DB_PASSWORD: ${DB_PASSWORD:-postgres}
      MONGO_HOST: ${MONGO_HOST:-mongo}
      MONGO_PORT: ${MONGO_PORT:-27017}
      MONGO_REPLICA_SET: ${MONGO_REPLICA_SET:-rs0}
      MONGO_DATABASE: ${MONGO_DATABASE:-bugbounty}
      MONGO_COLLECTION: ${MONGO_COLLECTION:-vulnerabilities}
      MONGO_PROGRAMS_COLLECTION: ${MONGO_PROGRAMS_COLLECTION:-scope}
      MONGO_ALIVE_COLLECTION: ${MONGO_ALIVE_COLLECTION:-alive}
      MONGO_CRAWL_COLLECTION: ${MONGO_CRAWL_COLLECTION:-crawl}
      MONGO_USERNAME: ${MONGO_USERNAME:-}
      MONGO_PASSWORD: ${MONGO_PASSWORD:-}
      MONGO_AUTH_SOURCE: ${MONGO_AUTH_SOURCE:-admin}
      MONGO_SERVER_SELECTION_TIMEOUT: ${MONGO_SERVER_SELECTION_TIMEOUT:-3}
      MONGO_CONNECT_TIMEOUT: ${MONGO_CONNECT_TIMEOUT:-3}
      ADMIN_USERNAME: ${ADMIN_USERNAME:-admin}
      ADMIN_PASSWORD: ${ADMIN_PASSWORD}
      RUNNER_TOKEN: ${RUNNER_TOKEN:-}
      WHITERABBIT_BIN: ${WHITERABBIT_BIN:-/usr/local/bin/whiterabbit}
      SCOPE_BIN: ${SCOPE_BIN:-/usr/local/bin/scope}
      CMDSCRIPT_HASH_SALT: ${CMDSCRIPT_HASH_SALT:-}
      RABBITMQ_HOST: ${RABBITMQ_HOST:-rabbitmq}
      RABBITMQ_PORT: ${RABBITMQ_PORT:-5672}
      RABBITMQ_HTTP_PORT: ${RABBITMQ_HTTP_PORT:-15672}
      RABBITMQ_USERNAME: ${RABBITMQ_USERNAME:-hunter}
      RABBITMQ_PASSWORD: ${RABBITMQ_PASSWORD:-hunter}
      RABBITMQ_TOKEN: ${RABBITMQ_TOKEN:-}
      CONTROL_CENTER_COMMAND_ALLOWLIST: ${CONTROL_CENTER_COMMAND_ALLOWLIST:-}
    ports:
      - "5000:5000"
    depends_on:
      db:
        condition: service_healthy
      mongo:
        condition: service_healthy
      rabbitmq:
        condition: service_healthy

  runner:
    image: ${REGISTRY_HOST:-10.0.1.2:3002}/${REGISTRY_OWNER:-gadmin}/${REGISTRY_REPO:-hunter}-runner:latest
    pull_policy: always
    restart: unless-stopped
    environment:
      HUNTER_API_URL: ${HUNTER_API_URL:-http://web:5000}
      RUNNER_TOKEN: ${RUNNER_TOKEN}
      RUNNER_POLL_INTERVAL: ${RUNNER_POLL_INTERVAL:-2}
      RUNNER_MAX_CONCURRENCY: ${RUNNER_MAX_CONCURRENCY:-30}
      CURL_MAX_TIME: ${CURL_MAX_TIME:-30}
      CURL_MAX_OUTPUT: ${CURL_MAX_OUTPUT:-262144}
    depends_on:
      web:
        condition: service_started
    user: "65534:65534"
    read_only: true
    tmpfs: ["/tmp"]
    cap_drop: ["ALL"]
    security_opt: ["no-new-privileges:true"]
    mem_limit: 512m
    pids_limit: 256

volumes:
  hunter_db:
  mongodb_data:
  rabbitmq_data:
```

- [ ] **Step 4: Run the check to verify it passes**

Run: `python3 /home/claude/workspace/scratch_check_compose.py`
Expected: `PASS (compose YAML valid, services/images/command correct)`

- [ ] **Step 5: Authoritative render (where docker exists) + clean up**

On a docker-capable host, with a minimal env for required vars:
```bash
cd /home/claude/workspace
SECRET_KEY_BASE=x ADMIN_PASSWORD=x RUNNER_TOKEN= \
  docker compose -f docker-compose.prod.yaml config >/dev/null && echo OK
```
Expected: `OK` (config renders; interpolation resolves). Substitute real secrets for an actual deploy.

Then remove the temporary check:
```bash
rm /home/claude/workspace/scratch_check_compose.py
```

- [ ] **Step 6: Commit**

```bash
cd /home/claude/workspace
git add docker-compose.prod.yaml
git commit -m "Add production compose that pulls the registry images for Portainer deploys" --author="Claude <noreply@anthropic.com>"
```

---

## Self-Review

**1. Spec coverage:**
- Spec §1 (workflow clone step + ref vars) → Task 2. ✓
- Spec §2 (Dockerfile scope stage) → Task 1. ✓
- Spec §3 (.dockerignore) → Task 1. ✓
- Spec §4 (web/Procfile.prod) → Task 3. ✓
- Spec §5 (docker-compose.prod.yaml) → Task 4. ✓
- Spec deploy-host prerequisites (insecure registry, registry auth, TLS proxy) → documented in Task 4's compose header. ✓
- Spec runtime note (RUNNER_TOKEN strong-or-empty) → documented in Task 4's web command comment. ✓
- Spec "runner image unchanged" → confirmed; no task modifies `runner/Dockerfile`. ✓

**2. Placeholder scan:** No TBD/TODO/"handle edge cases"; every step shows exact file content or exact commands. ✓

**3. Type/name consistency:** `scope-build` stage name, `/usr/local/bin/scope`, `SCOPE_BIN`, `tmp/whiterabbit`/`tmp/scope`, `Procfile.prod`, and the `${REGISTRY_HOST}/${REGISTRY_OWNER}/${REGISTRY_REPO}-{web,runner}:latest` image pattern are used identically across the Dockerfile, workflow, Procfile, and compose tasks. ✓
