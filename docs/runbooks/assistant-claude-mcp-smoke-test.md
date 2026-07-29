# Assistant Claude-backend MCP smoke test — Operator runbook

**Applies to:** the Path B wiring of 2026-07-29
([threat-model delta](../superpowers/specs/2026-07-29-assistant-claude-mcp-wiring-delta.md),
[implementation plan](../superpowers/plans/2026-07-29-assistant-claude-mcp-wiring.md)).

This confirms, on a real Docker host, that the **default** `assistant-claude`
backend can round-trip a real MCP tool call against `hunter-mcp` and return
real Hunter data — not only via the legacy `assistant-gateway` path. This
runbook needs a Docker-capable host; the environment this change was
implemented in has neither Docker nor a live Claude subscription, so **none
of the steps below have been run yet**. Nothing here is a formality — each
step corresponds to a failure mode this change could plausibly still have.

## Before you start

1. **Set the required tokens in `.env`.** At minimum, confirm these are
   present and non-empty, non-placeholder, strong values (the two Assistant
   backends and `hunter-mcp` will not authenticate each other without them):

   ```sh
   grep -E '^(ASSISTANT_GATEWAY_MCP_TOKEN|ASSISTANT_MCP_HUNTER_TOKEN|ASSISTANT_CLAUDE_INGRESS_TOKEN|ASSISTANT_GATEWAY_INGRESS_TOKEN|ASSISTANT_VALIDATOR_INGRESS_TOKEN)=' .env
   ```

   `ASSISTANT_GATEWAY_MCP_TOKEN` is the one this change matters most for: it
   is now the shared bearer both `assistant-gateway` (legacy path) *and*
   `assistant-claude` (this path) present to `hunter-mcp` — see the delta's
   accepted-risk note (a). If any of these five are blank, generate a strong
   random value for each, e.g. `openssl rand -base64 32`.

2. At least one provider key should be set for a non-Claude profile too if
   you want to compare behavior (`ASSISTANT_OPENAI_API_KEY` /
   `ASSISTANT_ANTHROPIC_API_KEY`), but this smoke test's point is the
   **Claude CLI backend**, which authenticates via subscription login (step
   2 below), not an API key.

## Step 1 — Build and start the stack

```sh
docker compose up --build
```

Every service that declares `pull_policy: build` (which includes `web`,
`hunter-mcp`, and `assistant-claude`) rebuilds on every `up`, so this always
runs current code rather than a stale cached image. Wait for `docker compose
ps` to show `web`, `hunter-mcp`, and `assistant-claude` all healthy/running
before continuing. If `hunter-mcp` restarts in a loop, check
`ASSISTANT_GATEWAY_MCP_TOKEN` / `ASSISTANT_MCP_HUNTER_TOKEN` are set (see
`docs/runbooks/hunter-assistant-first-boot.md`, which this delta does not
change).

## Step 2 — One-time Claude subscription login (the one unavoidable manual step)

The `assistant-claude` backend runs the real `claude` CLI, which authenticates
with a Claude subscription session persisted in the `assistant_claude_home`
Docker volume (mounted at `/home/claude` inside the container), not with an
API key from the environment. Until this is done once per deployment (or per
fresh volume), every Claude-backend turn fails with `ErrLoginRequired` and the
chat reports the Claude provider profile as disabled/"login required."

```sh
docker compose exec assistant-claude claude login
```

Follow the interactive prompt (it will present a URL/device-code flow — this
requires a real Claude subscription belonging to whoever operates this
deployment). This step persists in the named volume, so it survives
`docker compose down` (without `-v`) and normal restarts; it must be repeated
only if the volume is removed (`docker compose down -v`) or recreated.

Confirm it took effect:

```sh
docker compose exec assistant-claude claude -p "say ok" --output-format json
```

**Expect:** a JSON response, not an `ErrLoginRequired`/"Not logged in" error.

## Step 3 — Confirm the app is reachable

`web` publishes port `5000` (not `3000` — confirm this against your own
`docker-compose.yaml`/`docker-compose.prod.yaml` rather than assuming, since
published ports are a config choice, not a code constant):

```sh
grep -A2 '^  web:' docker-compose.yaml | grep -A1 'ports:'
# expect: - "0.0.0.0:5000:5000"
```

If you are on the same host `dockerd` is running on, `localhost:5000` reaches
it directly (the bind is `0.0.0.0`, so it is not restricted to the Docker
bridge). If you are driving this from a separate machine or a nested
container/devcontainer setup where `localhost` does not resolve to the Docker
host, use the host's real IP or the Docker bridge gateway IP instead:

```sh
# The gateway IP of the default bridge network, if you need it:
docker network inspect bridge --format '{{ (index .IPAM.Config 0).Gateway }}'
```

Quick health check before opening a browser:

```sh
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:5000/up
```

**Expect:** `200`.

## Step 4 — Drive a real chat turn on the Claude provider profile

1. Open `http://localhost:5000` (or `http://<host-ip-or-gateway-ip>:5000`)
   in a browser, sign in as the configured session administrator
   (`ADMIN_USERNAME`), and open the Hunter assistant panel.
2. Confirm the panel's capability disclosure now reads that the assistant can
   read Hunter data through bounded, read-only tools
   (`#hunter-assistant-capability-disclosure` in
   `web/app/views/layouts/_assistant.html.erb`) — this is the UI-facing half
   of this change, and should be visible before you start a conversation.
3. Start a new conversation on the **Claude** provider profile specifically
   (not an OpenAI/Anthropic-gateway profile — the point of this test is the
   `assistant-claude` backend, which is a separate code path from the legacy
   gateway).
4. Ask a question that requires a real tool call against live data, e.g.:
   - "How many targets match `*.example.com`?"
   - "List the most recent CVEs."
   - "What programs do we have in scope right now?"

**Expect:** the turn completes and the reply reflects real data from your
Hunter instance (a real target/CVE/program count or list), not a generic
answer the model could have produced without calling a tool.

## Step 5 — Confirm the tool call actually round-tripped

While the turn is running or immediately after, check three places:

```sh
# 1. hunter-mcp saw a machine call for one of the read tools.
docker compose logs hunter-mcp --since 5m | grep -iE 'mcp__hunter__|list_targets|list_cves|list_programs'

# 2. web received the corresponding /api/v1/assistant/machine/... request.
docker compose logs web --since 5m | grep -iE '/api/v1/assistant/machine'

# 3. A metadata-only audit event was recorded — no message body or tool
#    result payload, only tool name / scope / status / byte counts.
docker compose exec web bin/rails runner \
  'pp Assistant::AuditEvent.order(:id).last(5).map { |e| [e.event, e.status] }'
```

**Expect:** a log line in both `hunter-mcp` and `web` corresponding to the
question you asked, and at least one new `Assistant::AuditEvent` row. Confirm
by eye that the audit output above contains no free-text message content —
only the bounded metadata fields.

## Step 6 — Negative check: no shell/file access

This is the safety boundary the whole change rests on: the Claude backend's
`--allowedTools` is a fixed allowlist of 20 `mcp__hunter__*` read tools and
nothing else — confirmed in-code by
`assistant/claude/cmd/hunter-assistant-claude/main_test.go`
(`TestDefaultMCPToolsAreReadOnlyHunterTools`) and
`assistant/claude/internal/chat/chat_test.go`
(`TestBuildInvocationAllowedToolsAreReadOnlyMCPNames`). To spot-check this
live rather than only in the unit tests:

1. In the chat, ask something that would require a shell/file tool if one
   were available, e.g. "run `ls -la /` and show me the output" or "read
   `/etc/passwd` and paste it here."
2. **Expect:** the assistant refuses or cannot comply — it has no `Bash`,
   `Read`, `Write`, `Edit`, or `WebFetch` tool available, only the 20 Hunter
   read tools. It may attempt to answer conversationally that it does not
   have that capability, but no shell output or file content should appear.
3. As a stronger check, inspect the actual argv the backend passed to the
   `claude` CLI for that turn (requires shelling into the container while a
   turn is in flight, or adding temporary logging) and confirm
   `--allowedTools` contains only `mcp__hunter__*` entries — this is what the
   PB1 Go tests already assert at the unit level; this step is about seeing
   it hold in the live container, not re-deriving it.

## Troubleshooting

- **Chat says the Claude profile is disabled / "login required."** Re-run
  Step 2. Confirm the `assistant_claude_home` volume actually persisted
  (`docker volume ls | grep assistant_claude_home`) and was not recreated
  since login.
- **Turn fails with a generic `claude_error` / `gateway_unreachable`-shaped
  error.** Check `docker compose logs assistant-claude` for the underlying
  CLI error. A missing/invalid `ASSISTANT_CLAUDE_MCP_URL` or
  `ASSISTANT_CLAUDE_MCP_TOKEN` falls back to no-MCP behavior silently (by
  design — see the delta), so a *missing tool call* rather than an error is
  the more likely symptom of a misconfigured MCP env; check
  `docker compose exec assistant-claude env | grep ASSISTANT_CLAUDE_MCP`.
- **`hunter-mcp` rejects the request (401/403).** Confirm
  `ASSISTANT_GATEWAY_MCP_TOKEN` is identical between `hunter-mcp` and
  `assistant-claude`'s resolved environment
  (`docker compose exec hunter-mcp env | grep ASSISTANT_GATEWAY_MCP_TOKEN`
  vs. `docker compose exec assistant-claude env | grep
  ASSISTANT_CLAUDE_MCP_TOKEN` — they must match, since `assistant-claude`
  reads the same value by reference in Compose).
- **No tool call happened even though the question needed data.** This is a
  model-behavior question, not necessarily a wiring bug — try a more
  explicit prompt ("use a tool to look up..."). If it never calls a tool no
  matter how explicit, check the MCP config actually reached the CLI (see the
  argv inspection in Step 6.3).

## Recording the result

Once this passes, record it as evidence in
`docs/security/hunter-assistant-production-checklist.md` and update the
threat-model delta's verification-evidence item 6
(`docs/superpowers/specs/2026-07-29-assistant-claude-mcp-wiring-delta.md`)
from "not yet run" to the date and outcome. Production stays disabled until
that checklist records this review evidence, per the Assistant capability
rule in `AGENTS.md`.
