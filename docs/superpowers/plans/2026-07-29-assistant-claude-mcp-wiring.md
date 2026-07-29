# Assistant Claude-Backend MCP Wiring (Path B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make `docker compose up --build` turnkey so the DEFAULT zero-step `assistant-claude` backend can invoke the read-only MCP tools — i.e. the LLM → MCP → API workflow works out of the box, not only via the legacy gateway.

**Architecture:** Replicate, for the Claude path, exactly what the legacy gateway does: Rails issues a per-turn grant and passes the raw token to the backend; the backend presents it to `hunter-mcp` as `X-Hunter-Turn-Grant` plus `Authorization: Bearer <shared MCP token>`. The Claude CLI becomes the MCP client via a per-request `--mcp-config` (HTTP transport to `http://hunter-mcp:8080/mcp` with those two headers) locked down with `--strict-mcp-config` and an `--allowedTools` allowlist of ONLY the `mcp__hunter__*` read tools (never built-in Bash/Write/etc.). Compose puts `assistant-claude` on a network to `hunter-mcp` and gives it the MCP URL + token.

**Tech Stack:** Go 1.25 (`assistant/claude`), Ruby/Rails 8 (`web`), docker-compose. Claude Code CLI `@anthropic-ai/claude-code@2.1.220`.

## Confirmed facts (verified against the real CLI 2.1.201 and the codebase map)
- CLI flags: `--mcp-config <configs...>` (JSON file paths OR inline JSON string), `--strict-mcp-config` (ignore all ambient MCP config), `--allowedTools <tools...>` (comma/space list). HTTP MCP server schema `{"mcpServers":{"<name>":{"type":"http","url":"...","headers":{...}}}}` PARSES (verified: advanced to the turn, only stopped at `Not logged in`). MCP tool names are `mcp__<serverName>__<toolName>`.
- `--mcp-config` is variadic — it MUST be immediately followed by another `--flag` (e.g. `--strict-mcp-config`) so it doesn't swallow later positional args.
- Legacy template: raw grant (`Issuer.call` → `issuer.rb:54`) → envelope `turn_grant` field (`turn_dispatcher.rb:38`) → `GatewayClient` body → gateway sets `Authorization: Bearer <ASSISTANT_GATEWAY_MCP_TOKEN>` + `X-Hunter-Turn-Grant` on `http://hunter-mcp:8080/mcp` (StreamableHTTP, no Origin). MCP validates the single `GatewayToken` (`ASSISTANT_GATEWAY_MCP_TOKEN`) and reads the grant header.
- Claude path today: `turn_creator.rb:33-36` issues NO grant; `TurnJob.perform_later(claude: true, prompt:)` (`:146`) → `turn_job.rb:31-40` → `ClaudeCodeClient.run_turn` → POST `ASSISTANT_CLAUDE_URL/chat` body `{prompt, session_id}` (`claude_code_client.rb:22`). Backend `chat.go:35-40` runs `claude -p <prompt> --output-format json [--resume <sid>] --allowedTools ""`. `assistant-claude` is on networks `assistant-rails-claude`,`assistant-claude-egress` only; holds no MCP token.

## Global Constraints
- **Read-only lockdown is the safety boundary.** `--allowedTools` must contain ONLY `mcp__hunter__*` read tool names — NEVER a built-in tool (Bash/Write/Edit/Read/WebFetch/etc.). Always pass `--strict-mcp-config`. Never pass `--dangerously-skip-permissions`. The allowlist is configurable via env with a read-only default.
- The MCP token the Claude backend presents is the SAME shared secret the MCP validates (`ASSISTANT_GATEWAY_MCP_TOKEN`) — the MCP validates exactly one token digest. Do not invent a second token the MCP won't accept.
- The grant is per-turn, short-lived (`ASSISTANT_GRANT_TTL_SECONDS=300`), single-use budget. Issue it the same way the legacy path does (`Issuer.call`), bound to the turn's user/conversation/provider_profile.
- Backwards compatible: if the MCP env (`ASSISTANT_CLAUDE_MCP_URL`) is absent OR no grant is supplied, the backend behaves exactly as today (`--allowedTools ""`, no MCP). No regression to the existing Go/Rails tests.
- Per AGENTS.md capability rule: this grants the default backend access to the ALREADY-APPROVED read-only tools (dedicated scopes, grants, budgets, closed schemas, adversarial tests from Phase 2a–2c). It adds NO new tool, NO write/execute/send. A threat-model delta note (Task PB4) records the transport wiring, the read-only lockdown, the UI disclosure, and the adversarial tests. Production stays gated by the existing activation/kill-switch.
- Commit author `Claude <noreply@anthropic.com>`, one-sentence messages. Go tests `cd assistant/claude && go test ./...`. Rails tests: env recipe `cd web && set -a; . ../.env; set +a; export DB_HOST=172.17.0.1 DB_PORT=5433 DB_DATABASE_TEST=hunter_test; bin/rails test <files>`.

---

### Task PB1: Claude backend — per-request MCP config + locked-down argv

**Files:**
- Modify: `assistant/claude/cmd/hunter-assistant-claude/main.go` (read new env, thread into chat config + request body)
- Modify: `assistant/claude/internal/chat/chat.go` (build MCP config file + argv)
- Test: `assistant/claude/internal/chat/chat_test.go`, `assistant/claude/cmd/hunter-assistant-claude/main_test.go`

**Interfaces:**
- Produces: chat config carries `MCPURL string`, `MCPToken string`, `AllowedTools []string` (from env). `chat.Request` gains `TurnGrant string`. When `MCPURL != "" && Request.TurnGrant` is valid → the CLI runs with `--mcp-config <tmpfile>` + `--strict-mcp-config` + `--allowedTools <join(AllowedTools)>`; otherwise unchanged (`--allowedTools ""`).
- `chatRequestBody` gains `TurnGrant *string \`json:"turn_grant"\``.

- [ ] **Step 1: Write failing tests (chat_test.go)** for a new argv/config builder. Refactor the argv assembly in `chat.go` into a pure, testable function, e.g. `buildInvocation(cfg Config, req Request) (args []string, mcpConfigPath string, cleanup func(), err error)`. Assert:
  - With `cfg.MCPURL=""`: args == `["-p", prompt, "--output-format","json","--allowedTools",""]` (plus `--resume sid` when set); no mcp config file; cleanup is a no-op. (Preserves today's behavior.)
  - With `cfg.MCPURL` set + valid `req.TurnGrant`: args contain, in order, `-p <prompt> --output-format json [--resume <sid>] --mcp-config <path> --strict-mcp-config --allowedTools <joined>`; `--mcp-config` is immediately followed by `--strict-mcp-config`; the written file at `<path>` is JSON `{"mcpServers":{"hunter":{"type":"http","url":<MCPURL>,"headers":{"Authorization":"Bearer <MCPToken>","X-Hunter-Turn-Grant":<grant>}}}}`; `--allowedTools` value equals `strings.Join(cfg.AllowedTools, " ")` and every entry starts with `mcp__hunter__` (assert NONE is a built-in like `Bash`/`Write`/`Read`/`Edit`/`WebFetch`).
  - With `cfg.MCPURL` set but `req.TurnGrant=""` OR grant containing a control char/space/>1024 chars: falls back to the no-MCP form (no config file written) — a missing/invalid grant must never produce an unauthenticated MCP config. (Reuse the gateway's `validGrant` rule: non-empty, ≤1024, no `\x00\r\n\t` or space.)
  - The temp MCP config file is created mode 0600 under the process tmp dir and `cleanup()` removes it.

- [ ] **Step 2: Run tests to verify failure** — `cd assistant/claude && go test ./internal/chat/` → FAIL (function absent).

- [ ] **Step 3: Implement in chat.go** — add `Config{ MCPURL, MCPToken string; AllowedTools []string; Timeout ... }` (fold existing fields), implement `buildInvocation`, write the config file to `os.MkdirTemp`/`os.CreateTemp` (0600), and have the chat handler call `buildInvocation`, exec `claude`, and `defer cleanup()`. Marshal the config with `encoding/json` (do NOT hand-format). Keep the existing `--output-format json` result parsing and the `Not logged in` → `ErrLoginRequired` mapping (the CLI returns `is_error:true,result:"Not logged in · Please run /login"` — ensure that still maps to a login error, and that an MCP tool-call turn's success is parsed the same way).

- [ ] **Step 4: Implement in main.go** — read env: `ASSISTANT_CLAUDE_MCP_URL` (default `""`), `ASSISTANT_CLAUDE_MCP_TOKEN` (default `""`), `ASSISTANT_CLAUDE_MCP_TOOLS` (default the 20 read tools joined by space — see list below). Build `chat.Config` from them. Add `TurnGrant *string \`json:"turn_grant"\`` to `chatRequestBody` and thread `*body.TurnGrant` (or "") into `chat.Request{...TurnGrant:}`. Default `ASSISTANT_CLAUDE_MCP_TOOLS`:
  `mcp__hunter__list_targets mcp__hunter__get_target mcp__hunter__list_cves mcp__hunter__get_cve mcp__hunter__list_vulnerabilities mcp__hunter__get_vulnerability mcp__hunter__list_endpoints mcp__hunter__get_endpoint mcp__hunter__list_programs mcp__hunter__get_program mcp__hunter__list_templates mcp__hunter__get_template mcp__hunter__list_jobs mcp__hunter__get_job mcp__hunter__list_playbooks mcp__hunter__get_playbook mcp__hunter__list_run_groups mcp__hunter__get_run_group mcp__hunter__get_run mcp__hunter__list_run_events`

- [ ] **Step 5: Run tests to verify pass** — `cd assistant/claude && go test ./... && gofmt -l . && go vet ./...` → all pass/clean.

- [ ] **Step 6: Commit** — `git add assistant/claude/ && git commit -m "Give the Claude assistant backend a per-turn MCP config and read-only tool allowlist."`

---

### Task PB2: Rails — issue and thread a per-turn grant on the Claude path

**Files:**
- Modify: `web/app/services/assistant/turn_creator.rb` (Claude branch: issue grant, pass raw to the job)
- Modify: `web/app/jobs/assistant/turn_job.rb` (accept + forward the grant)
- Modify: `web/app/services/assistant/claude_code_client.rb` (send `turn_grant` in the body)
- Test: `web/test/services/assistant/turn_creator_test.rb`, `web/test/jobs/assistant/turn_job_test.rb` (if present), `web/test/services/assistant/claude_code_client_test.rb`

**Interfaces:**
- Produces: on the Claude path `Issuer.call` mints a grant (bound to the turn) and its raw token flows to `ClaudeCodeClient.run_turn(turn:, prompt:, turn_grant:)`, which includes `"turn_grant" => turn_grant` in the `/chat` JSON body. When grant issuance is disabled/absent the body omits `turn_grant` (or sends `null`) and the backend falls back to no-MCP.

- [ ] **Step 1: Write failing tests.** `claude_code_client_test.rb`: stub the HTTP POST and assert the body includes `turn_grant` when passed. `turn_creator_test.rb`: creating a turn on a `claude_code` provider profile issues a grant (a `TurnGrant` row bound to the turn) and enqueues `TurnJob` with the raw grant; assert the grant carries the read scopes/tools (reuse the Issuer behavior). Keep an assertion that the legacy path is unchanged.

- [ ] **Step 2: Run to verify failure** (env recipe) → FAIL.

- [ ] **Step 3: Implement.** In `turn_creator.rb` Claude branch (currently `:33-36`/`:139-148`): call `Assistant::Grants::Issuer.call(turn: turn, resources: [], tools: Assistant::Grants::Issuer::TOOLS)` to get `raw_grant`, and enqueue `Assistant::TurnJob.perform_later(turn_id: turn.id, claude: true, prompt: prompt, turn_grant: raw_grant)`. (Mirror the legacy path's grant issuance; keep the `ensure raw_grant&.clear`.) In `turn_job.rb` (`:24,:31-40`): accept `turn_grant:` and pass it to `ClaudeCodeClient.run_turn(turn:, prompt:, turn_grant:)`. In `claude_code_client.rb` (`:22`): add `"turn_grant" => turn_grant` to the body hash when present. Do NOT log the raw grant.

- [ ] **Step 4: Run tests to verify pass** (targeted files) → PASS.

- [ ] **Step 5: Commit** — `git add web/app/services/assistant/turn_creator.rb web/app/jobs/assistant/turn_job.rb web/app/services/assistant/claude_code_client.rb web/test/ && git commit -m "Issue and thread a per-turn MCP grant to the Claude assistant backend."`

---

### Task PB3: Compose wiring so assistant-claude reaches hunter-mcp

**Files:**
- Modify: `docker-compose.yaml` (and mirror the same additions in `docker-compose.prod.yaml`)
- Test: static validation (`python3 -c "import yaml,sys; yaml.safe_load(open('docker-compose.yaml'))"`) + a documented reasoning check; no runtime test (no Docker in this env).

**Interfaces:**
- Produces: `assistant-claude` joins a network shared with `hunter-mcp` and gets `ASSISTANT_CLAUDE_MCP_URL`, `ASSISTANT_CLAUDE_MCP_TOKEN`; `hunter-mcp` accepts the Claude client's Origin.

- [ ] **Step 1: Add a dedicated internal network** `assistant-claude-mcp: { internal: true }` under `networks:`. Add it to BOTH `hunter-mcp.networks` and `assistant-claude.networks`.
- [ ] **Step 2: Add env to `assistant-claude`:**
  - `ASSISTANT_CLAUDE_MCP_URL: http://hunter-mcp:8080/mcp`
  - `ASSISTANT_CLAUDE_MCP_TOKEN: ${ASSISTANT_GATEWAY_MCP_TOKEN}` (the exact secret hunter-mcp validates)
  - (Optionally expose `ASSISTANT_CLAUDE_MCP_TOOLS` for override; default lives in the binary.)
- [ ] **Step 3: Widen the MCP Origin allowlist** so the Claude CLI's HTTP client is accepted regardless of whether it sends an Origin: set `hunter-mcp` env `ASSISTANT_MCP_ALLOWED_ORIGINS: http://assistant-gateway:8081,http://hunter-mcp:8080`. (Empty Origin is already allowed; adding the server's own URL covers a client that sets Origin to the target. `Host: hunter-mcp:8080` is already in `ASSISTANT_MCP_ALLOWED_HOSTS`.) Verify the MCP config parser splits `ASSISTANT_MCP_ALLOWED_ORIGINS` on comma (check `assistant/mcp/internal/config/config.go`); if it splits on comma this is correct.
- [ ] **Step 4: Confirm `web` already has `ASSISTANT_CLAUDE_URL`** (it does) — no change. Ensure `.env.example`/README documents `ASSISTANT_GATEWAY_MCP_TOKEN` must be set (it is required by both hunter-mcp and now assistant-claude).
- [ ] **Step 5: Validate** — `python3 -c "import yaml; yaml.safe_load(open('docker-compose.yaml')); yaml.safe_load(open('docker-compose.prod.yaml')); print('compose YAML OK')"`. Confirm (by reading) that `assistant-claude` and `hunter-mcp` now share `assistant-claude-mcp`.
- [ ] **Step 6: Commit** — `git add docker-compose.yaml docker-compose.prod.yaml && git commit -m "Network the Claude assistant backend to hunter-mcp with the shared MCP token."`

---

### Task PB4: UI disclosure, threat-model note, runbook + self-check

**Files:**
- Create: `docs/superpowers/specs/2026-07-29-assistant-claude-mcp-wiring-delta.md` (threat-model delta)
- Create: `docs/runbooks/assistant-claude-mcp-smoke-test.md` (host self-check for the operator)
- Modify: the assistant chat view/partial that discloses assistant capabilities (find the existing disclosure used by the legacy path; if the chat already lists available tools, ensure the Claude path reflects that read-only tools are available) — if no such disclosure element exists, add a one-line static disclosure in the assistant settings/chat partial and a test.
- Test: a view/presence test if a disclosure element is added.

- [ ] **Step 1: Threat-model delta** — one page: capability = default backend may invoke the existing approved read-only MCP tools; controls = read-only lockdown (`--allowedTools` allowlist of `mcp__hunter__*` only, `--strict-mcp-config`, no skip-permissions), per-turn grant (scope + budget + TTL + bindings), shared MCP token over an internal-only network, metadata-only audit (unchanged), adversarial tests (PB1 argv lockdown; existing runner scope/secret-rejection). Production still gated by activation/kill-switch. No new tool, no write/execute/send.
- [ ] **Step 2: Operator smoke-test runbook** — the exact host steps: set `ASSISTANT_GATEWAY_MCP_TOKEN` (+ the other tokens) in `.env`; `docker compose up --build`; one-time `docker compose exec assistant-claude claude login` (subscription auth in the `assistant_claude_home` volume — this is the one unavoidable manual step); open the app at the docker gateway `http://<gateway>:3000`, start a chat on the Claude profile, ask a question that needs data (e.g. "how many targets match *.example.com"), and confirm a tool call round-trips (check `assistant-claude`/`hunter-mcp`/`web` logs for the machine call + a metadata audit event). Include a curl-level check hitting `web` `/up` or the assistant bootstrap on `:3000`.
- [ ] **Step 3: Disclosure** — locate the existing capability disclosure; ensure it's accurate for the Claude path. Add a test if you add an element.
- [ ] **Step 4: Commit** — `git add docs/ web/ && git commit -m "Document and disclose the Claude backend MCP read-tool capability."`

---

### Task PB5: Full verification (in-process) + live-CLI schema smoke test

- [ ] **Step 1: Go** — `cd assistant/claude && go test -count=1 ./... && go vet ./... && gofmt -l .` (all pass/clean). Also `cd assistant/mcp && go test ./...` (unchanged, still green).
- [ ] **Step 2: Rails** — env recipe; `bin/rails test test/services/assistant/ test/jobs/assistant/ test/integration/api/v1/assistant/` (all pass). Then the FULL suite with `CONTROL_CENTER_COMMAND_ALLOWLIST` UNSET (dev-env artifact — see the phase2c ledger) → expect 0 failures.
- [ ] **Step 3: Live-CLI schema smoke test (best-effort, no login)** — using the real `claude` CLI present in the dev sandbox, run `buildInvocation`'s output shape against the CLI to confirm the generated `--mcp-config` JSON is accepted (it will stop at `Not logged in`, which proves the config parsed). Record the command + output. This substitutes for the container boot that Docker-absence prevents.
- [ ] **Step 4: Compose YAML validation** — `python3 -c "import yaml; [yaml.safe_load(open(f)) for f in ('docker-compose.yaml','docker-compose.prod.yaml')]; print('OK')"`.
- [ ] **Step 5: No commit** — verification only. Record honest evidence, and explicitly state the one gate that cannot run here: the live `docker compose up --build` boot on the operator's Docker host (+ the one-time `claude login`).

---

## Self-Review

**Coverage:** grant issuance+threading on the Claude path (PB2) mirrors the legacy template; backend MCP client via confirmed CLI flags (PB1); compose reachability + token + origin (PB3); disclosure + threat-model + operator runbook (PB4); verification incl. the live-CLI schema check that substitutes for the un-runnable container boot (PB5).

**Safety invariants:** `--allowedTools` is an allowlist of ONLY `mcp__hunter__*` read tools (PB1 test asserts no built-in appears); `--strict-mcp-config` always set; invalid/missing grant ⇒ no MCP config (never an unauthenticated tool surface); MCP token is the exact secret the server validates; network is `internal: true`. Read-only throughout; no new tool or effectful op.

**No placeholders:** exact env var names, the exact 20-tool allowlist, the exact `--mcp-config` JSON shape (verified against the CLI), and the variadic-flag ordering constraint are all specified.

**Honest limit:** no Docker in the build env — the container boot on `:3000` and the one-time `claude login` are operator steps documented in the runbook; everything else is automatic on `compose up --build`.
