# Assistant First Boot — Operator Verification

**Applies to:** the infrastructure simplification of 2026-07-27
([design](../superpowers/specs/2026-07-27-assistant-infra-simplification-design.md),
[delta](../superpowers/specs/2026-07-27-assistant-infra-simplification-delta.md))

The Assistant now reaches its provider keys and machine tokens through
environment variables, and Rails calls the gateway and validator directly over
HTTP. RabbitMQ, the squid egress proxy, the Rails event consumer and all three
bootstrap one-shots are gone. `docker compose up` is the whole enablement step.

## Why this document exists

The build environment this change was developed in had **no Docker and no
PostgreSQL**. Every Go suite passed. Of the seven database-free Ruby suites
(files that boot Rails' `config/environment` directly, or load no Rails
environment at all, rather than going through `test_helper`'s Postgres
fixtures), all seven now pass, 0 failures / 0 errors:
`test/contracts/assistant_secret_paths_test.rb`,
`test/config/assistant_release_gate_test.rb`,
`test/config/assistant_compose_test.rb`,
`test/services/assistant/validator_client_test.rb`,
`test/services/assistant/gateway_client_test.rb`,
`test/services/assistant/provider_credentials_test.rb`, and
`test/jobs/assistant/turn_job_test.rb`. Two of them
(`assistant_release_gate_test.rb`, and a since-deleted
`rabbitmq_provisioner_test.rb` that a `LoadError` on a removed file was
aborting the whole `bin/rails test` run with) were failing/erroring as of the
final review on 2026-07-27 because they still referenced the deleted
RabbitMQ/rotation-drill machinery; both were fixed and re-verified as part of
that review. Nothing that requires a container or a live database was
executed. The checks below are therefore **unverified** and must be run once
before this change is trusted. Nothing here is a formality — each item
corresponds to a failure mode the change could plausibly still have.

## What was verified, and how

| Verified | Evidence |
|---|---|
| All three Go modules build, vet, gofmt and test clean | 18 packages, 0 failures; `-race -count=3` clean on the concurrency tests |
| Gateway/validator ingress rejection behaviour | Every error code covered, incl. wrong-bearer, check-order precedence, and real-concurrency saturation |
| Gateway and validator agree on the shared ingress contract | `assistant/contracts/v1/http_ingress_cases.json` read by both suites; guard confirmed to fire when one service diverges |
| Go and Ruby classify provider keys identically | Nine inputs compared, including both oversize boundaries |
| Compose topology and secret placement | 8 Assistant-relevant services (plus Whiterabbit's broker), 0 `./secrets` mounts, no `assistant_secrets` volume, no provider key on `runner`/`ansible-executor` |
| Rails boots with the AMQP broker deleted | `Assistant::Broker` undefined; app loads |
| Activation reports enabled from environment alone | `Assistant::Activation.state` → `active=true, reason=active, slugs=["openai_primary","anthropic_primary"]` |

**Not verified:** container boot, database migrations and seeding, and every
ActiveRecord-dependent test (`bin/rails test` needs PostgreSQL).

## Before you start

`.env` has already been populated with all six secrets. The two provider keys
were migrated from the retired `secrets/` files; the four machine tokens were
freshly generated. Confirm with:

```sh
grep -c '^ASSISTANT_' .env      # expect 8 or more
```

Two activation gates were set to their **narrowest working values**. Widen them
deliberately if you need more:

```
CONTROL_CENTER_COMMAND_ALLOWLIST=curl
ASSISTANT_ANSIBLE_MODULE_ALLOWLIST=ansible.builtin.debug
```

An empty `CONTROL_CENTER_COMMAND_ALLOWLIST` means *any* binary is permitted,
which is why the Assistant refuses to activate until it is set explicitly.

## Step 1 — Boot from clean

```sh
docker compose down -v
docker volume ls | grep assistant_secrets || echo "volume absent (expected)"
docker compose build          # NOT optional -- see below
docker compose up -d
docker compose ps
```

**`docker compose build` is required, not a formality.** In development `web`
bind-mounts `./web:/app`, so Ruby changes take effect on restart with no rebuild —
which makes it easy to assume the whole stack behaves that way. It does not.
`assistant-gateway`, `assistant-validator` and `hunter-mcp` are `build:` services
with a compiled Go binary baked into the image, so they keep running the OLD
binary until rebuilt.

A stale gateway binary fails in a specific, confusing way: the pre-simplification
build read its machine credentials from `/run/assistant/secrets` and its provider
keys from `/run/secrets`, both of which this change deletes. It therefore exits
with `assistant gateway configuration rejected`, crash-loops under
`restart: unless-stopped`, and Rails — which can no longer open a socket to it —
reports every turn as **`gateway_unreachable`**. The chat unlocks and accepts a
message, then never answers.

**Expect:** nine services — `db`, `mongo`, `web`, `assistant-gateway`,
`hunter-mcp`, `assistant-validator`, `runner`, `ansible-executor`, and
`rabbitmq`. All healthy, none restarting.

`rabbitmq` is **not** part of the Assistant. The Assistant used to share it as a
turn transport; it now reaches the gateway over HTTP and needs no broker. The
service survives only because Control Center's `whiterabbit` CLI uses RabbitMQ,
so it runs the stock image with no Assistant vhost, AMQP users, or provisioning
one-shot. `assistant-gateway`, `assistant-validator` and `hunter-mcp` are not on
the `default` network, so none of them can reach it at all.

`hunter-mcp` is the one to watch: it used to read its two tokens from files on
the deleted volume and `log.Fatal` if they were absent. It now reads
`ASSISTANT_GATEWAY_MCP_TOKEN` and `ASSISTANT_MCP_HUNTER_TOKEN` from the
environment. A crash-loop here means those variables are unset or contain
whitespace.

### If a service exits 255 with "reopen exec fifo"

```
assistant-gateway-1  | reopen exec fifo: get safe /proc/thread-self/fd handle:
                       fstatfs fsmount:fscontext:proc: operation not permitted
assistant-gateway-1 exited with code 255 (restarting)
```

This is container init failing, not the Go binary. `assistant-gateway`,
`assistant-validator` and `hunter-mcp` run under deny-by-default seccomp profiles
in `ops/assistant/seccomp/`. runc 1.2 and later call `fstatfs` on the exec fifo's
descriptor — to prove it is not a procfs magic link — *after* the profile is
applied, so a profile without `fstatfs` kills every such container with `EPERM`.

Fixed on 2026-07-27 by allowing `fstatfs`/`fstatfs64` and switching
`defaultErrnoRet` from `1` (EPERM) to `38` (ENOSYS), so a denied syscall now
reads as unimplemented and the runtime's fallback paths engage instead of
hard-failing. `assistant_compose_test.rb` asserts both, so it cannot regress.

Note the new mount API — `fsopen`, `fsmount`, `fsconfig`, `fspick`,
`move_mount`, `open_tree` — is deliberately still denied and is now refused by
name in that test. Those grant the mounting power `mount` is denied for; the
strings `fsmount` and `fscontext` in the error above are the filesystem types
runc was *checking for*, not syscalls it needs. Do not add them.

If a *different* syscall is reported, add only that one, and add a matching
assertion to `assistant_compose_test.rb`.

## Step 2 — Confirm the deleted failure modes are gone

```sh
docker compose logs web assistant-gateway assistant-validator hunter-mcp 2>&1 \
  | grep -Ei "master.key|EACCES|traces|amqp|rabbit|squid" || echo "clean"
```

**Expect:** `clean`. Note the log scope is limited to the four services this
change touched — Whiterabbit's `rabbitmq` legitimately logs about AMQP. Two
boot-blocking defects found on 2026-07-27 — a
root-owned `config/master.key` in a `user: 1000` container, and `/api/traces`
requiring a RabbitMQ plugin the image never enabled — both lived in machinery
this change deletes.

## Step 3 — Confirm the seed installed the machine identity

```sh
docker compose exec web bin/rails runner \
  'i = Assistant::ServiceIdentity.find_by(name: "hunter-mcp", enabled: true); \
   puts i ? "installed ##{i.id} role=#{i.role}" : "MISSING"'
```

**Expect:** `installed #<id> role=mcp_reader`. Postgres stores only the SHA-256
digest — the raw token must never appear in a database row.

Re-run `docker compose exec web bin/rails db:seed` and confirm it is idempotent
(no new row, no error). Then set `ASSISTANT_MCP_HUNTER_TOKEN` back to a
previously used value and seed again: it must **reactivate** that row rather than
raise `ActiveRecord::RecordNotUnique`, because `token_digest` carries an
unqualified unique index.

## Step 4 — Confirm activation

```sh
docker compose exec web bin/rails runner 'pp Assistant::Activation.state'
```

**Expect:** `active: true`, `reason: "active"`, and one slug per provider key you
set. If it reports `no_provider_credentials`, one of the keys is empty,
whitespace-only, still `replace_with_your_key`, or over 16 KiB. If it reports
`missing_command_allowlist` or `missing_ansible_module_allowlist`, see
"Before you start".

## Step 5 — Confirm the negative paths

```sh
# Unauthenticated /turns must be refused.
docker compose exec web sh -c \
  'curl -s -o /dev/null -w "%{http_code}\n" -XPOST http://assistant-gateway:8081/turns -d "{}"'

# Unauthenticated /validations must be refused.
docker compose exec web sh -c \
  'curl -s -o /dev/null -w "%{http_code}\n" -XPOST http://assistant-validator:8082/validations -d "{}"'

# A schemeless token must also be refused (both services require "Bearer ").
docker compose exec web sh -c \
  'curl -s -o /dev/null -w "%{http_code}\n" -XPOST http://assistant-gateway:8081/turns \
     -H "Authorization: $ASSISTANT_GATEWAY_INGRESS_TOKEN" -d "{}"'
```

**Expect:** `401` from all three, with a JSON body `{"error":{"code":"unauthorized"}}`.

Confirm the execution services never received provider keys:

```sh
docker compose exec runner env | grep -c ASSISTANT_.*API_KEY || echo "0 (expected)"
docker compose exec ansible-executor env | grep -c ASSISTANT_.*API_KEY || echo "0 (expected)"
```

**Expect:** `0` from both. A contract test asserts this in the compose files;
this confirms it in the running containers.

## Step 6 — Drive one real turn

Log in as `ADMIN_USERNAME`, open the chat, and send a prompt. A real provider
call will be billed.

**Expect:** the composer is enabled, the turn moves `queued → running →
completed`, and an assistant message renders.

If the turn stays `queued`, the Solid Queue worker is not running — check
`foreman` started the `worker` process from the Procfile, and that
`db/queue_schema.rb` loaded. If it goes straight to `failed`, read
`error_code`: `gateway_not_ready` means no provider credential resolved inside
the gateway container, `gateway_saturated` means both turn slots were busy, and
`gateway_unreachable`/`gateway_timeout` means the network path or the provider
call failed.

Then confirm the audit trail carries no message bodies:

```sh
docker compose exec web bin/rails runner \
  'pp Assistant::AuditEvent.order(:id).last(5).map { |e| [e.event, e.status] }'
```

## Step 7 — Run the suites that need a database

```sh
docker compose exec web bin/rails test
```

**Expect:** all pass. These were written but never executed:
`activation_test.rb`, `config_test.rb`, `conversations_test.rb`,
`assistant_end_to_end_test.rb`, `turns_test.rb`, `machine/tools_test.rb`,
`confirmed_save_test.rb`, `event_ingestor_test.rb`, `turn_creator_test.rb`,
`turn_dispatcher_test.rb`, `validation_dispatcher_test.rb`,
`service_identity_test.rb`, `assistant_service_tokens_test.rb`.

Several had their stubs retargeted from the deleted `Assistant::Broker` to the
real new boundaries (`TurnJob.perform_later`, `ValidatorClient.validate`). If any
fail, the likely cause is an assertion still shaped around the old asynchronous
delivery — the validator now answers synchronously, so a validation request
reaches its terminal state within the same call.

## Step 8 — Clean up

Once the stack is confirmed working, the migrated key files are dead weight and
should be removed:

```sh
rm secrets/assistant_anthropic_api_key secrets/assistant_openai_api_key
rmdir secrets
```

They were never tracked by git (`.gitignore: /secrets/*`), so no history rewrite
is needed. Nothing reads them any more.

## Production

Production stays disabled until
[`../security/hunter-assistant-production-checklist.md`](../security/hunter-assistant-production-checklist.md)
records review evidence for this design, per the Assistant capability rule in
`AGENTS.md`. Completing this runbook is a precondition for that review, not a
substitute for it.
