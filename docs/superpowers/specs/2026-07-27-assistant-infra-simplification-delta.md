# Threat-model delta — Assistant infrastructure simplification (2026-07-27)

Status: **APPROVED**

Base documents:

- `docs/superpowers/specs/2026-07-27-assistant-infra-simplification-design.md`
- `docs/superpowers/specs/2026-07-25-hunter-assistant-security-design.md`
- `docs/security/hunter-assistant-threat-model.md`
- `docs/security/hunter-assistant-production-checklist.md`
- `docs/runbooks/hunter-assistant-incident-response.md`
- `docs/superpowers/specs/2026-07-26-hunter-assistant-zero-step-activation-delta.md`
  (amended by this document — see its 2026-07-27 amendment note)
- `AGENTS.md` — "Assistant capability change rule"

## What this delta covers

The design document above replaces RabbitMQ, the squid egress allowlist, the
Rails event consumer, and all three bootstrap one-shots with a direct HTTP
call from a Solid Queue job to the provider gateway, and moves every Assistant
secret from a mounted file to a process environment variable. The retained
privilege separation — the gateway has no Hunter identity, `hunter-mcp` is the
only path from the model side to Hunter data and holds no provider key, the
validator has no Hunter identity, inventory, SSH credential, or target route —
is unchanged and remains the point of the design; this delta does not touch
it.

This document is the required threat-model delta for that change under the
"Assistant capability change rule" in `AGENTS.md`, and records the five
accepted security consequences from §6 of the design document: what the
removed control was, what replaced it, why the residual risk is accepted, and
what would reverse the decision. It also updates the threat model, production
checklist, and incident-response runbook (in their own commits) and amends the
zero-step activation delta, whose activation mechanism this change alters.

## Change 1 — the gateway gains unrestricted egress

**Control removed.** `assistant-egress` (squid) enforced an HTTPS-only
allowlist limited to the OpenAI and Anthropic API domains. The gateway had no
direct route to the Internet; every outbound call was forced through that
allowlist, denying plaintext HTTP, arbitrary domains, loopback, private,
link-local, metadata, and invalid-certificate destinations.

**What replaced it.** Nothing. `assistant-gateway` now has ordinary outbound
network reach from within its container. The gateway's own code still only
constructs requests to the fixed OpenAI/Anthropic base URLs and rejects
redirects, but that is an application-level constraint, not a network-level
one — a compromise of the gateway process itself (not merely a hostile
provider response) is no longer contained by an external allowlist.

**Residual risk accepted because:** the gateway is precisely the component
that parses untrusted, attacker-influenced provider output, so it was already
the highest-value target for an egress-escape exploit; the operator judged
that removing squid — one of the eight Compose services, its own network, and
a whole Dockerfile/entrypoint to maintain — was worth accepting broader reach
for a compromise that would already be severe. The reduction is partly
recoverable at the Docker network layer (a host firewall rule or Docker
network policy restricting `assistant-gateway`'s egress to the two provider
IP ranges), so operators with that capability are not left with no lever, only
without the one this design shipped built-in.

**What would reverse this decision:** reintroducing a network-level egress
allowlist (squid or an equivalent, or a host/Docker-network firewall rule
scoped to `assistant-gateway`) as a required, tested part of the stack.

## Change 2 — the broker's per-user authorization is replaced, not reproduced

**Control removed.** RabbitMQ enforced per-user permissions on the assistant
vhost: Rails could write only to `assistant.turns` and read only from
`assistant.rails.*`; the gateway and validator had their own scoped
permissions. This was authorization enforced by the broker itself, independent
of anything the application code did.

**What replaced it.** An internal-only Docker network (`assistant-gateway` and
`assistant-validator` are reachable only from services on the Rails-facing
network) plus a single bearer token per endpoint
(`ASSISTANT_GATEWAY_INGRESS_TOKEN` for `POST /turns`,
`ASSISTANT_VALIDATOR_INGRESS_TOKEN` for `POST /validations`), checked with a
constant-time comparison, plus Host and Origin allowlisting on the gateway.
There is exactly one legitimate caller (the Rails Solid Queue job) and exactly
one route per service, so the substitution is a single all-or-nothing
credential rather than the broker's fine-grained read/write matrix.

**Residual risk accepted because:** for a single-consumer, single-route shape
— Rails is the only caller, `/turns` and `/validations` are the only routes —
a per-topic permission matrix and a single bearer token protect the same
thing: only Rails may invoke the gateway/validator, and neither can address
each other or anything else. The broker's finer grain had no second consumer
to distinguish. The operator accepted this as a substitution, not a downgrade
in practice, while recording explicitly that it is not the same mechanism.

**What would reverse this decision:** a second legitimate caller of `/turns`
or `/validations` emerging (which would require distinguishing callers again,
e.g. per-caller tokens or mTLS identities) or evidence that the bearer token
is more exposed in practice than RabbitMQ credentials were (see Change 3).

## Change 3 — secrets are readable wherever the process environment is

**Control removed.** Every Assistant secret was a file under `./secrets` or
the `assistant_secrets` Docker volume, bind- or volume-mounted read-only into
exactly the containers that needed it. `ops/assistant/verify_compose_security.sh`
and the secret-paths contract test could prove a given container's mount was
genuinely read-only, and file ownership/mode (`0400`/`0600`, uid 1000) gave an
independent, checkable proof of correct scoping.

**What replaced it.** A process environment variable, declared per service
under `environment:` (never `env_file`), for each of the six secrets. There is
no `/run/secrets` mount, no `/run/assistant/secrets` mount, and no
`assistant_secrets` volume any more. `docker inspect`, `/proc/<pid>/environ`,
`docker compose config`, and any diagnostic tool that dumps a container's
environment now expose every secret that container holds. File modes and
ownership can no longer be verified because there is no file — the
read-only-mount proof this design previously relied on is gone outright, not
weakened.

**Residual risk accepted because:** this is the direct, necessary cost of
deleting the two bootstrap one-shots, the `assistant_secrets` volume, and the
RabbitMQ dependency ordering that gated `web` on that volume being populated —
machinery whose own failure modes (a root-owned `config/master.key` a
`uid 1000` container cannot read; an undocumented `rabbitmq_tracing` plugin
requirement) had already caused two boot-blocking defects. The operator judged
a smaller, simpler secret-distribution surface — with a documented, weaker
guarantee — preferable to a larger one whose stronger guarantee had already
failed to boot in practice. Per-service scoping (which service receives which
variable) is unchanged and is the property carried forward; only the
file-mode/read-only-mount *proof* of that scoping is gone.

**What would reverse this decision:** returning to a file- or
Compose-secrets-backed distribution mechanism that boots reliably (the
requirement that forced this change), for example Docker Compose's native
`secrets:` support once the file-absent-is-a-boot-failure behaviour that ruled
it out for the zero-step activation goal is no longer a constraint (e.g. if
zero-step activation is dropped as a requirement, or Compose gains an
optional-secret mode).

## Change 4 — provider key material lives in the Ruby heap for the process lifetime

**Control removed.** The file-based design's `PREFIX_BYTES` read optimisation
existed specifically to avoid copying full key bytes into a Ruby `String` on
every activation check: `Assistant::ProviderCredentials#reason_for` read only a
bounded 128-byte prefix from disk per call, so a live key value was resident
in the Ruby heap only for the duration of that read, not continuously.

**What replaced it.** An environment variable is read once, at process
start, into `ENV`, which is a Ruby `Hash` backed by C strings that persist for
the life of the process. The value is resident in the Ruby/OS process memory
from boot until the container exits, and can appear in a heap dump, core
dump, or swapped page for the entire process lifetime — not just during an
activation check.

**Residual risk accepted because:** this is an unavoidable consequence of the
env-var secret model chosen in Change 3, not an independent design choice —
any process that reads a secret from its environment necessarily holds it in
memory for its own lifetime. Mitigating this within Ruby (e.g. scrubbing
`ENV` after reading each key into a locked, single-purpose buffer) would
still leave the *original* copy in `ENV` unless it is deleted outright, which
would break every subsequent activation check and any code path that reads the
key value to make the provider call. The operator accepted heap/core-dump
exposure as bounded by the same process boundary that already holds the key
to make provider calls in the first place — the gateway must have the live
key value in memory to call the provider, so this consequence does not create
a new component with access, only a longer window on the one that already
had it.

**What would reverse this decision:** moving secret access behind a
dedicated secret-manager client (e.g. an HSM or a KMS-backed decrypt-on-use
call) rather than an ambient environment variable, so the gateway process
never holds the raw key value longer than the individual outbound request.

## Change 5 — subprocesses inherit the environment

**Control removed.** With file-mounted secrets, a provider key never appeared
in any process's environment at all — reading it required an explicit
`File.read` of a specific path. Any subprocess `web` spawned (Whiterabbit,
scope tooling) received nothing unless it was separately, explicitly given the
file path and permission to read it.

**What replaced it.** `web` now holds `ASSISTANT_ANTHROPIC_API_KEY` and
`ASSISTANT_OPENAI_API_KEY` in its own process environment (see the zero-step
activation amendment — Rails must read these to decide and disclose
activation). Any subprocess `web` spawns without deliberately clearing its
environment inherits both keys implicitly by default, where a file-based
design required an explicit grant.

**Residual risk accepted because:** the implemented mitigation directly
addresses the two Compose services with a genuine subprocess-spawning
purpose. `runner` and `ansible-executor` are declared in Compose without
`env_file` and are not listed as consumers of either provider-key
environment variable, so they do not receive `ASSISTANT_ANTHROPIC_API_KEY` or
`ASSISTANT_OPENAI_API_KEY` even though they run in the same deployment. This
is asserted by a contract test (the rewritten
`test/contracts/assistant_secret_paths_test.rb`) rather than left as an
unverified Compose-file convention, so a future edit that adds `env_file` or
an explicit key to either service's definition is caught before it ships. The
residual risk is scoped to processes Rails itself spawns directly (in-process
subprocess calls, if any, made by `web`'s own request-handling code), which
this delta does not further restrict.

**What would reverse this decision:** if `web` gains a subprocess-spawning
code path that does not already clear the provider-key variables from the
child's environment, that path must either explicitly strip them or this
delta must be revisited to add a contract test covering it, before that path
ships.

## What is retained unchanged

The gateway has no Hunter identity. `hunter-mcp` is the only path from the
model side to Hunter data and holds no provider key. The validator has no
Hunter identity, no inventory, no SSH credential, and no route to targets.
Postgres stores only digests (`ASSISTANT_MCP_HUNTER_TOKEN`'s digest, minted by
`db:seed`, not a raw value). The model-facing path still cannot save,
schedule, cancel, or execute — Control Center's existing persistence paths
remain the sole save and execution authorities. None of this delta's five
accepted consequences touches this separation.

## Explicitly out of scope

This delta does **not** introduce, widen, or relax:

- any Assistant context type, tool, provider feature, user role, write action,
  or execution action
- any generic network, search, shell, filesystem, credential, write, send,
  schedule, or execution tool
- any wildcard scope for a service or turn-grant identity
- the six-tool MCP catalog, or any bound, limit, retention window, or
  sanitizer
- the `progress` event kind's removal is a schema simplification (Rails now
  owns turn status transitions directly), not a new capability

## Required verification evidence

1. A contract test asserting `runner` and `ansible-executor` do not receive
   `ASSISTANT_ANTHROPIC_API_KEY` or `ASSISTANT_OPENAI_API_KEY` in the resolved
   Compose configuration, and that no service uses `env_file` to load the
   whole `.env`.
2. A compose test asserting no service mounts `./secrets` and no
   `assistant_secrets` volume exists in either compose file.
3. Gateway `POST /turns` and validator `POST /validations` tests: auth
   rejection (missing/wrong bearer token), Host/Origin rejection, saturation
   `503`, not-ready `503`, and envelope validation.
4. Rails job tests: single attempt (no automatic retry), an `error` event
   recorded on gateway failure, and atomic ingestion of the whole ordered
   event array.
5. A secret-leak gate over Git history, image layers, resolved Compose output,
   and logs, confirming no secret value or full-length key appears anywhere
   these were not previously found (the risk in Change 3 is about *inspection
   surface*, not new leak vectors — the gate should still pass).
6. A live `docker compose up` on a Docker-capable host, from `.env` only,
   reaching a successful chat turn when a valid provider key is present — run
   by the operator. **Not yet run** as of this document; the build/review
   environment used to draft this delta has no Docker and no Postgres. Every
   statement above about boot-time or request-time behaviour is the intended,
   designed behaviour pending that operator verification, not a confirmed
   observation.

Items 1–5 are automated. Item 6 is a release gate recorded in the production
checklist, which must continue to show **Not run** until an operator records
its output.

## Approval

- Operator approval: **APPROVED 2026-07-27** (carried from the design
  document's own approval — see
  `docs/superpowers/specs/2026-07-27-assistant-infra-simplification-design.md`)
- Threat-model delta reviewed by: **UNSET**
- Date: **UNSET**

Production stays disabled until the production checklist records review
evidence for this design, per the Assistant capability rule in `AGENTS.md`.
