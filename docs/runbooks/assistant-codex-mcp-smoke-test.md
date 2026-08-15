# Assistant direct-provider and Codex MCP smoke test

This runbook records the operator-only evidence required before Hunter's
subscription-backed Codex and Claude Code Assistant may be enabled. It covers
login persistence, the exact Codex/Hunter MCP boundary, live browser turns,
metadata-only audit checks, and rollback. It does not enable the Assistant.

Keep `ASSISTANT_ENABLED=false` and the database Assistant switch off until an
independent Reviewer approves the exact candidate image digests in
`docs/security/hunter-assistant-production-checklist.md`.

Never paste a login credential, ingress bearer, turn grant, prompt, reply,
provider event, session/thread ID, or unredacted Compose output into release
evidence. `docker compose config` expands environment values; capture only a
reviewed redacted copy in the approved evidence system.

## 1. Fix the candidate and prerequisites

Record the source commit and immutable image digests before testing. The active
Assistant path requires `web`, `hunter-mcp`, `assistant-codex`, and
`assistant-claude`. `assistant-gateway` and `assistant-validator` are dormant
rollback services under the `legacy-gateway` profile and are not part of a
normal direct-provider start.

Generate the narrowly named service credentials if this is a new deployment:

```sh
ops/assistant/generate_secrets.sh dev
```

Confirm without printing values that these variables are non-empty:

- `ASSISTANT_MCP_HUNTER_TOKEN`
- `ASSISTANT_GATEWAY_MCP_TOKEN` (the bearer both direct runners present to
  `hunter-mcp`)
- `ASSISTANT_CODEX_INGRESS_TOKEN`
- `ASSISTANT_CLAUDE_INGRESS_TOKEN`

They must be distinct except for the intentional mapping of
`ASSISTANT_GATEWAY_MCP_TOKEN` into each runner's service-specific MCP token
environment variable. Neither direct runner may receive `OPENAI_API_KEY`,
`CODEX_API_KEY`, `ANTHROPIC_API_KEY`, `ASSISTANT_OPENAI_API_KEY`, or
`ASSISTANT_ANTHROPIC_API_KEY`.

Build or pull the exact candidate, then start the active services:

```sh
docker compose up -d db mongo rabbitmq web hunter-mcp assistant-codex assistant-claude
docker compose ps
```

All listed services must be running and every defined health check must become
healthy. Do not continue through a restart loop.

## 2. Verify pins and container isolation

The candidate must report the reviewed CLI versions:

```sh
docker compose run --rm --no-deps --entrypoint codex assistant-codex --version
docker compose run --rm --no-deps --entrypoint claude assistant-claude --version
```

Expected pins are `codex-cli 0.144.4` and Claude Code `2.1.220`. Record the
complete version output with the candidate digest.

Verify the direct services run as uid 1000, their roots are read-only, the
Codex work directory is immutable, and only the matching login home is writable:

```sh
docker compose exec assistant-codex sh -c \
  'test "$(id -u)" = 1000 && test ! -w /workspace && test -w /home/codex/.codex'
docker compose exec assistant-claude sh -c \
  'test "$(id -u)" = 1000 && test ! -w / && test -w /home/claude'
```

Verify the forbidden API-key names are absent without printing any environment
value:

```sh
docker compose exec assistant-codex sh -c \
  'for n in OPENAI_API_KEY CODEX_API_KEY ASSISTANT_OPENAI_API_KEY; do ! printenv "$n" >/dev/null; done'
docker compose exec assistant-claude sh -c \
  'for n in ANTHROPIC_API_KEY ASSISTANT_ANTHROPIC_API_KEY; do ! printenv "$n" >/dev/null; done'
```

Inspect and record only network names, mounts, security options, limits, and
image digests for the four active services. Confirm:

- neither direct runner publishes a host port or mounts a host path;
- `assistant_codex_home` is mounted only by `assistant-codex` and
  `assistant_claude_home` only by `assistant-claude`;
- each runner has exactly its Rails ingress, Hunter MCP, and provider-egress
  networks;
- `hunter-mcp` has no provider-egress or datastore network; and
- all active Assistant services retain `cap_drop: ALL`, read-only root,
  `no-new-privileges`, the reviewed seccomp profile, and bounded resources.

Run the resolved-configuration gate. For the live denial probe, also start the
normal runner and the opt-in Ansible executor with their valid deployment
tokens so they can serve as forbidden-network sentinels:

```sh
ops/assistant/verify_compose_security.sh
docker compose --profile ansible up -d runner ansible-executor
ops/assistant/test_network_denials.sh
ops/assistant/check_secret_leaks.sh
```

The secret gate additionally requires the pinned `gitleaks` and Trivy
toolchain. Exit status `77` means a runtime, service, or scanner is unavailable;
it is pending evidence, never a pass.

## 3. Prove the exact Codex tool boundary

Run the process-level tests on the exact source used for the image. They start
loopback fake provider/MCP servers and invoke the installed pinned binary; they
must run, not skip:

```sh
cd assistant/codex
PATH=/usr/local/go/bin:$PATH go test ./internal/chat \
  -run 'TestRealCodex(EnforcesApprovedHunterMCPBoundary|ApplyPatchCannotMutateReadOnlyWorkspace)' \
  -count=1 -v
cd ../..
```

The capture must show exactly these eight Codex-owned top-level tools and no
ninth tool:

```text
list_mcp_resources
list_mcp_resource_templates
read_mcp_resource
update_plan
request_user_input
apply_patch
view_image
tool_search
```

The only deferred MCP source must be `hunter`; its tool names and input schemas
must exactly equal `Assistant::Grants::Issuer::CHAT_TOOLS` after the Control
Center write toggle narrows them. The patch probe must report a failed custom
tool result and leave `forbidden.txt` absent.

## 4. Establish subscription logins and persistence

For a fresh Codex login volume, first submit one browser turn before logging in
and record the stable `codex_login_required` outcome. Do not delete or log out an
already approved production credential merely to recreate this check; use a
fresh isolated test project/volume instead.

Perform the one-time interactive logins as the same uid and against the same
named volumes used by the services:

```sh
docker compose run --rm --no-deps --entrypoint codex assistant-codex login --device-auth
docker compose run --rm --no-deps --entrypoint codex assistant-codex login status
docker compose run --rm --no-deps --entrypoint claude assistant-claude login
```

Codex must authenticate through ChatGPT device authorization. Do not use
`--with-api-key`, `--with-access-token`, or an API-key environment variable.

Restart both services without removing volumes, then confirm login status and
a simple provider-only invocation still succeed:

```sh
docker compose restart assistant-codex assistant-claude
docker compose exec assistant-codex codex login status
docker compose exec assistant-claude claude -p "Reply with only: ok" --output-format json
```

Treat the Claude reply as sensitive provider output: inspect it locally, but do
not attach it to the production checklist. Never run `docker compose down -v`
during this procedure; that removes the credential volumes.

## 5. Authenticated browser smoke through port 5000

Sign in as the configured Hunter Assistant administrator at the deployment's
port 5000 browser origin. Use unique canary strings for the prompt, reply, MCP
read, and any authoring test. Keep the values in the secure test worksheet, not
in the checklist.

For OpenAI/Codex:

1. Open Hunter Assistant and activate the OpenAI logo twice rapidly. Verify one
   conversation is created, both choices lock during the request, the composer
   receives focus, and no browser console error appears.
2. Submit a request that requires one harmless Hunter read, such as listing one
   program name. Verify the response uses real Hunter data and the UI shows the
   OpenAI identity.
3. Submit a second message in the same conversation. Verify resume succeeds and
   no second conversation is created.

Repeat the three checks through the Anthropic choice. Verify its identity is
independent and that the Codex and Claude continuity fields never cross.

Also verify:

- a legacy transcript is readable, renameable/reorderable/deletable by its
  human owner, marked `Legacy conversation · read-only`, and has a disabled
  composer;
- posting a turn to a legacy conversation returns
  `409 legacy_provider_retired` with no new turn, message, grant, audit, or job;
- history collapse/expand, code compact/expand, and complete code copy work;
- an unavailable direct service produces a stable namespaced failure such as
  `codex_connection_refused` or `claude_connection_refused`, never a raw error;
  and
- enabling/disabling the Assistant and Control Center write switches revokes
  only their documented paths.

If authoring is in the approved deployment scope, exercise one create and one
explicit optimistic-lock edit for each permitted artifact type. Confirm strict
validation, human attribution, metadata-only audit, no confirmation prompt,
and no delete/run/send/schedule capability.

## 6. Audit, error, and log canaries

Inspect only metadata columns from recent Assistant audit events:

```sh
docker compose exec web bin/rails runner \
  'puts Assistant::AuditEvent.order(id: :desc).limit(50).pluck(:event, :status, :model, :tool, :resource_type, :resource_id, :metadata).to_json'
```

Expected fields are stable IDs/categories/outcomes/reasons only. Prompt, reply,
code, tool arguments, title, order arrays, login material, turn grants,
session/thread IDs, raw CLI events, and provider errors must be absent.

Use each secure canary to search the recent `web`, `hunter-mcp`,
`assistant-codex`, and `assistant-claude` logs plus API error bodies. Expected:
no match. If a match appears, stop, preserve the evidence under incident
handling, rotate affected credentials, and keep production disabled. Do not
paste the matched sensitive line into this checklist.

Record the tested time window, candidate digest, commands, stable outcomes, and
redacted artifact checksums in the production checklist.

## 7. Rollback without rewriting history

Rollback is an operator action, not an automatic provider fallback:

1. Set the environment and database Assistant kill switches off and verify
   there are no active grants.
2. Preserve both direct login volumes and all conversation rows. Never rewrite
   `provider_profile_id`, `codex_thread_id`, or `claude_session_id`.
3. Redeploy the previously approved web and Assistant image digests. If that
   candidate uses the token-backed gateway, start its dormant services with
   `docker compose --profile legacy-gateway up -d assistant-gateway assistant-validator`.
4. Run that candidate's recorded smoke and credential checks before re-enable.
5. Record the exact rollback digests, operator, time, reason, and validation
   result in the production checklist.

A partial rollback that starts `legacy-gateway` while leaving the current Rails
code deployed does not reactivate legacy chat: current conversation creation
still rejects profile IDs and current turns still reject legacy profiles. This
is intentional. History is preserved until the complete previously approved
candidate is restored.
