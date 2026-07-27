# Assistant Infrastructure Simplification

**Date:** 2026-07-27

**Status:** Approved

**Module:** Assistant (cross-cutting; `docker-compose*.yaml`, `assistant/`, `web/app/services/assistant/`)

**Supersedes transport decisions in:**
[`2026-07-25-hunter-assistant-security-design.md`](2026-07-25-hunter-assistant-security-design.md)

**Amends:**
[`2026-07-26-hunter-assistant-zero-step-activation-delta.md`](2026-07-26-hunter-assistant-zero-step-activation-delta.md)
— activation is now derived from environment variables, not key files.

## 1. Summary

The Assistant shipped with eight of the stack's fourteen Compose services, seven
internal networks, a RabbitMQ vhost, an outbound HTTP proxy, and three bootstrap
one-shots. The privilege separation that motivated it is retained; the transport
and secret-distribution machinery around it is removed.

The retained separation is unchanged and remains the point of the design:

- `assistant-gateway` holds provider keys, reaches the provider, and reasons. It
  has **no Hunter identity** and never initiates a connection to Hunter.
- `hunter-mcp` is the only path from the model side to Hunter data. It holds
  **no provider key**.
- `assistant-validator` has no Hunter identity, no inventory, no SSH credential,
  and no route to targets.

What is removed: RabbitMQ as the Rails↔gateway transport, the squid egress
allowlist, the long-running Rails event consumer, and all three bootstrap
one-shots. Services go 14 → 8; internal networks 7 → 4.

## 2. Goals and non-goals

**Goals**

- Rails forwards a turn directly to the gateway over HTTP; the gateway returns
  the result on the same connection.
- Delete RabbitMQ, squid, `assistant-events`, and the three one-shots.
- Distribute every secret as an environment variable.
- Preserve the gateway/MCP/validator privilege separation exactly.

**Non-goals**

- Token streaming to the browser. No SSE or Turbo Stream exists today; the
  browser polls. The endpoint is shaped so streaming is a later drop-in
  (§4.1) but nothing streams in this change.
- Any change to the MCP tool catalog, turn-grant model, serializers, retention,
  rate limits, or the Control Center save/execute authorities.
- Moving activation off derived-from-credential semantics. Activation remains
  derived; only its input changes from file presence to env presence.

## 3. Target architecture

```
browser ──cookie + CSRF──▶ Rails API ──HTTP (held open)──▶ assistant-gateway ──HTTPS──▶ provider
                            │  ▲                            │
                     202 +  │  │ ordered event array        │
                     poll   │  │ (closed schema)            ▼
                            │  └────────────────────────  hunter-mcp ──▶ Rails machine API
                            │                                            (grant-scoped reads)
                            └──HTTP──▶ assistant-validator
```

Rails answers the browser's POST with `202` and runs the turn in a Solid Queue
job. The job sets the turn `running`, POSTs the turn envelope to the gateway, and
holds the connection. The gateway performs the provider call and the MCP tool
loop, then returns an ordered array of assistant events. The job validates each
against the existing closed schema and ingests them in one transaction.

**Services kept:** `db`, `mongo`, `web`, `assistant-gateway`, `hunter-mcp`,
`assistant-validator`, `runner`, `ansible-executor`.

**Services deleted:** `rabbitmq`, `assistant-egress`, `assistant-events`,
`assistant-secrets-init`, `assistant-token-init`, `assistant-rabbitmq-init`.

**Networks:** `rails↔gateway`, `gateway→mcp`, `mcp→rails`, `rails↔validator`,
plus the gateway's outbound path to the provider.

### 3.1 Why return-in-response rather than a callback

A callback would require giving the gateway a Hunter identity and credential.
Returning the result on the request Rails already opened keeps the gateway a pure
request/response worker with no Hunter identity, which is the property
`hunter-assistant-threat-model.md` depends on. With
`ASSISTANT_MAX_CONCURRENT_TURNS: 2`, at most two jobs are ever parked on a
socket.

## 4. Contracts

### 4.1 `POST /turns` (Rails → gateway)

Reachable only on the `rails↔gateway` internal network.

- **Auth:** `Authorization: Bearer $ASSISTANT_GATEWAY_INGRESS_TOKEN`,
  constant-time compare. Plus `ASSISTANT_GATEWAY_ALLOWED_HOSTS` and
  `ASSISTANT_GATEWAY_ALLOWED_ORIGINS`, mirroring the Host/Origin rebinding
  defence `hunter-mcp` already implements.
- **Request:** today's turn envelope unchanged — the ten keys of
  `QueueContracts::TURN_JOB_KEYS`, validated by `validate_turn_job!` before the
  request is sent.
- **Response 200:** `{"schema_version": 1, "correlation_id": "…", "events": […]}`
  — an ordered array, each element validated by `validate_assistant_event!`.
  Total response bounded by the existing `MAX_EVENT_BYTES` (300,000), which
  becomes a whole-response cap rather than a per-event one.
- **Response non-2xx:** `{"error": {"code": "…"}}`. The job records an `error`
  event through the normal ingestion path.
- **Deadline:** derived from the envelope's existing `expires_at` (the turn
  grant expiry). The grant is therefore the turn deadline by construction; the
  gateway cannot outlive the credential it was given. No new configuration.
- **Saturation:** `503` when the gateway's in-flight semaphore is at
  `ASSISTANT_MAX_CONCURRENT_TURNS` — this replaces the broker's `prefetch`.
- **Not ready:** `503` while no provider credential resolves, preserving the
  idle-when-unconfigured behaviour.
- **Streaming-ready shape:** the response body is an array of the same event
  objects that a future `text/event-stream` would emit one at a time. No
  envelope change is required to add streaming later.

### 4.2 `POST /validations` (Rails → validator)

Same auth shape with `ASSISTANT_VALIDATOR_INGRESS_TOKEN`. Request body is today's
validation request envelope; response is today's validation event.
`ValidationDispatcher.ingest!` is unchanged — only its trigger moves.

### 4.3 Schema changes

- **The `progress` event kind is removed.** Rails owns turn status transitions
  now: the job sets `running` before the POST and `completed`/`failed` after.
  This deletes an event kind and the ordering hazard where a `progress` event
  could arrive after `completed`.
- Ingestion becomes atomic: the whole ordered array is written in one
  transaction instead of N independent deliveries.
- `event_id` remains a gateway-minted UUID; Rails keeps deduplicating on it.

### 4.4 Retry semantics

**Exactly one attempt.** The gateway is not idempotent with respect to provider
spend, so a retry means a second billed provider call and can double-write a
draft. Solid Queue attempts once; failure records an `error` event and the user
resends from the chat UI. The rejected alternative — a `turn_id`-keyed result
cache in the gateway — adds state to the component that most needs to stay
stateless.

## 5. Secret model

Every secret is an environment variable. There is no `/run/secrets` mount, no
`/run/assistant/secrets` mount, and no `assistant_secrets` volume.

| Secret | Consumer | Was |
|---|---|---|
| `ASSISTANT_ANTHROPIC_API_KEY` | gateway, web | file in `./secrets` |
| `ASSISTANT_OPENAI_API_KEY` | gateway, web | file in `./secrets` |
| `ASSISTANT_GATEWAY_MCP_TOKEN` | gateway, hunter-mcp | generated → volume |
| `ASSISTANT_MCP_HUNTER_TOKEN` | hunter-mcp, web (seed) | minted → volume |
| `ASSISTANT_GATEWAY_INGRESS_TOKEN` | web, gateway | new |
| `ASSISTANT_VALIDATOR_INGRESS_TOKEN` | web, validator | new |

Four AMQP passwords and the RabbitMQ provisioning password are deleted outright.

**Declared per service, never via `env_file`.** `runner` and `ansible-executor`
currently load the whole `.env`; broadcasting provider keys to them would widen
exposure for no reason. Each secret is listed under the `environment:` key of
exactly the services that need it, using `${VAR}` substitution.

**The service-identity digest moves into `db:seed`.** `web` already runs
`bundle exec rails db:seed` on boot. The seed reads
`ASSISTANT_MCP_HUNTER_TOKEN`, digests it with the existing
`Assistant::ServiceIdentity.digest`, and upserts the `hunter-mcp` identity.
Postgres continues to store only the SHA-256 digest. `Assistant::BootstrapServiceToken`
and its runner script are deleted.

### 5.1 Activation, derived from environment

`Assistant::Activation` keeps deriving state from credentials; the input changes.
`ProviderCredentials` classifies an env var instead of a file, so its reason
codes reduce:

- **Retained:** `absent`, `empty`, `placeholder`, `oversize`, `valid`
- **Deleted:** `symlink`, `bad_mode`, `unreadable` — all file-only conditions

`DEFAULT_DIRECTORY`, `ACCEPTED_MODES`, and the `PREFIX_BYTES` read optimisation
are deleted. The catalog's `secret_file` key becomes `secret_env`, and the
gateway's `defaultSecretFiles` map becomes an env-name map; the contract test
that keeps the two in agreement is rewritten against the new key.

The gateway's `safeSecretMode` probe — which accepted a `0600` key only when a
write-open failed, proving the mount was genuinely read-only — is deleted along
with `machineSecretDir` and `LoadFrom`.

## 6. Accepted security consequences

These are deliberate reductions, accepted by the operator, and recorded here so
they are not rediscovered as defects.

1. **The gateway gains unrestricted egress.** squid enforced an allowlist limited
   to provider domains. The gateway is the component that parses untrusted
   provider output, so a compromise there now gains arbitrary outbound reach.
   Partly recoverable at the Docker network layer; not equivalent.
2. **The broker's authorization layer is replaced, not reproduced.** RabbitMQ
   enforced per-user permissions (Rails could write only `assistant.turns` and
   read only `assistant.rails.*`). That becomes an internal-only network plus a
   bearer token on a single endpoint — comparable for a single-consumer path, but
   a substitution.
3. **Secrets are readable wherever the process environment is.** `docker inspect`,
   `/proc/<pid>/environ`, `docker compose config`, and any diagnostic that dumps
   the environment all expose them. File modes and ownership can no longer be
   verified, so the read-only-mount proof is gone.
4. **Provider key material lives in the Ruby heap for the process lifetime.**
   The `PREFIX_BYTES` design existed to avoid copying key bytes into a String on
   every activation check; with env vars the value is resident from boot and can
   appear in heap or core dumps.
5. **Subprocesses inherit the environment.** Anything `web` spawns (whiterabbit,
   scope) receives the provider keys implicitly, where a file read was explicit.

Retained unchanged: the gateway has no Hunter identity; MCP is the only path to
Hunter data and holds no provider key; the validator has neither; Postgres stores
only digests; the model-facing path cannot save or execute.

## 7. Reliability effect

The current design fails silently: a dropped AMQP message or a stopped
`assistant-events` leaves a turn in `queued` with nothing to observe. A
synchronous call either returns an envelope or raises, and every failure becomes
an `error` event. Two boot-blocking defects found on 2026-07-27 (`config/master.key`
readable only by root in a `user: 1000` container; `/api/traces` requiring a
`rabbitmq_tracing` plugin the image never enables) both live in the machinery
this change deletes.

The dependency chain also flattens. Today `hunter-mcp` waits on two one-shots,
`web` waits on `rabbitmq`, and `rabbitmq` waits on `secrets-init`, so any
one-shot failure takes down the whole stack. After: `web` waits on `db` and
`mongo`; `hunter-mcp` waits on `web`; the gateway and validator wait on nothing.
No container boots Rails read-only any more.

## 8. Deletion inventory

**Ops (~517 LOC):** `ops/assistant/provision_rabbitmq.rb` (191),
`ops/assistant/rabbitmq/entrypoint.sh` (195), `assistant/egress/squid.conf` (74),
`ops/assistant/bootstrap.sh` (31), `ops/assistant/bootstrap_service_token.rb`
(15), plus the rabbitmq and egress Dockerfiles and `hash_password.sh`.

**Rails (~144 LOC plus the bootstrap service):** `broker.rb` (97),
`event_consumer.rb` (47), `bootstrap_service_token.rb`. Retargeted, not deleted:
`turn_dispatcher.rb`, `validation_dispatcher.rb`. `queue_contracts.rb` survives —
it validates the same envelopes over a different transport.

**Go:** far less than a whole package. In `internal/queue/consumer.go` only
`Run` (192-244) and `publishEvent` (245-269) are AMQP-specific — roughly 78 LOC,
plus the `eventExchange`/`eventRoutingKey` constants and the `amqp` import.
Everything else is already transport-agnostic and survives verbatim:
`DecodeTurnJob` (98), `Process` (126), `newEvent` (270), `errorEvent` (278),
`decodeClosed` (293), `unsafeText` (305), `ConnectMCP` (317), and the
`TurnJob`/`AssistantEvent`/`Processor` types. `Process` already derives its
deadline from `ExpiresAt` capped by `maxTurnDuration`, so §4.1's deadline rule is
existing behaviour, not new work. The package is therefore **renamed**
`internal/queue` → `internal/turn` rather than deleted.

The validator has the identical shape: `DecodeJob` (61), `Process` (76),
`validResult` (182) survive; `Run` (104-153) and `publishEvent` (154-181) go.

Both services **already run an HTTP server** — gateway at `0.0.0.0:8081`
(`cmd/hunter-assistant-gateway/main.go:21`), validator at `0.0.0.0:8082` — each
with a `/healthz` handler and a `-healthcheck` client mode. This change adds one
route to each existing mux. `internal/provider` (755), `internal/mcp` (137), and
`internal/prompt` (59) are untouched.

**Compose:** six services, three networks, the `assistant_secrets` volume, the
`./secrets` bind mounts, and the upgrade hazard documented at
`docker-compose.yaml:606-613`.

## 9. Testing

- **Deleted:** `test/config/assistant_rabbitmq_entrypoint_test.rb`;
  the `bootstrap.sh` and token-bootstrap cases in
  `test/config/assistant_bootstrap_test.rb`.
- **Rewritten:** `test/contracts/assistant_secret_paths_test.rb` — the
  volume-read and read-only-mount assertions are replaced by per-service
  environment assertions, including a new test that `runner` and
  `ansible-executor` do **not** receive provider keys.
  `test/config/assistant_compose_test.rb` — `ALLOWED_HOST_MOUNTS`,
  `ASSISTANT_SECRETS_VOLUME_RO`, and `NETWORKS` all change.
- **Retained:** the build-context test asserting `web/config/master.key` is
  excluded. It matters more now, since `.env` holds provider keys (`.env` and
  `.env.*` are already excluded, with `!.env.example`).
- **New:** gateway `POST /turns` handler tests (auth reject, Host/Origin reject,
  saturation `503`, not-ready `503`, deadline from `expires_at`, envelope
  validation); Rails job tests (single attempt, error-event on failure, atomic
  ingestion of the event array); a compose test asserting no service mounts
  `./secrets` and no `assistant_secrets` volume exists.

Mongo stays doubled in tests and no live RabbitMQ is needed anywhere — one fewer
integration dependency.

## 10. Migration

1. Generate four tokens (`openssl rand -base64 32`) and add them plus the two
   provider keys to `.env`; `.env.example` documents all six.
2. `docker compose down` and `docker volume rm <project>_assistant_secrets`.
3. Rebuild. `db:seed` upserts the `hunter-mcp` identity from
   `ASSISTANT_MCP_HUNTER_TOKEN`; any pre-existing enabled `mcp_reader` identity
   is rotated to disabled by the same seed.
4. Production stays disabled until the checklist records evidence for this
   design, per the Assistant capability rule in `AGENTS.md`.
