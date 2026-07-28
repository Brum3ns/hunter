# Hunter Assistant Threat Model

**Version:** 1

**Date:** 2026-07-25

**Status:** Required security baseline; the assistant remains disabled until the
production checklist is approved.

## Scope

This threat model covers Hunter's administrator-only assistant, including the
browser chat, Rails assistant endpoints and persistence, the direct HTTP call
Rails makes to the provider gateway, the provider gateway itself, the Go MCP
broker, and the network-constrained Ansible draft validator. The assistant
authors drafts only. Existing Control Center paths remain the sole save and
execution authorities.

The full design is
[`docs/superpowers/specs/2026-07-25-hunter-assistant-security-design.md`](../superpowers/specs/2026-07-25-hunter-assistant-security-design.md).

## Protected assets

- Hunter session, API, runner, executor, service, and turn-grant credentials
- OpenAI and Anthropic API keys
- Ansible SSH credentials and secret variable values
- Program, target, vulnerability, CVE, template, and playbook data
- Conversation bodies and generated drafts
- Integrity of saved automation artifacts and execution boundaries
- Availability and auditability of Hunter's control plane

## Trust boundaries

Rails, PostgreSQL, and the Docker host are trusted. The browser is trusted only
after session authentication, CSRF verification, and exact `ADMIN_USERNAME`
authorization. Provider output, selected record content, the provider gateway,
MCP broker, validator input, and all prompt text are untrusted.

Docker-host control is administrative control over the entire deployment.
Every assistant secret is supplied as a process environment variable rather
than a mounted file, so a host administrator who can inspect a container,
read `/proc/<pid>/environ`, or run `docker compose config` can already read
it; this is treated as within the existing Docker-host trust boundary, not a
new one, and the resulting reduction in routine-exposure protection is
recorded as an accepted consequence in
[`docs/superpowers/specs/2026-07-27-assistant-infra-simplification-delta.md`](../superpowers/specs/2026-07-27-assistant-infra-simplification-delta.md).
Hunter has no dependency on an external deployment-control product.

## Data flow

```text
Browser session + CSRF
  -> Rails assistant API (202 response, browser polls)
  -> encrypted PostgreSQL state + metadata-only audit
  -> Solid Queue job holds a bearer-token-authenticated HTTP call to the
     provider gateway (internal network only)
       -> HTTPS -> selected OpenAI or Anthropic profile
       -> authenticated MCP request + opaque turn grant
  -> Go MCP broker
  -> MCP-reader authentication + same turn grant
  -> sanitized Rails machine API
  <- ordered array of closed-schema assistant events, ingested atomically

Confirmed save:
Browser review + CSRF
  -> Rails final validation
  -> ordinary Control Center persistence service
```

The browser never receives provider, service, RabbitMQ, or turn-grant
credentials. The gateway has no Hunter identity. MCP has no provider key. The
validator has no Hunter identity, inventory, SSH credential, or target route.

## Principal threats and required controls

### Prompt injection and hostile model output

Selected records may contain instructions that impersonate system messages.
The gateway labels them untrusted and never interpolates them into system or
developer instructions. Security relies on absent capabilities: the fixed MCP
catalog cannot search, write, execute, browse, access secrets, or proxy generic
requests. Provider output must match a closed message or draft schema and is
rendered as escaped text.

### Unauthorized data disclosure

Only records explicitly selected by the administrator are included in a turn
grant. Rails and MCP both enforce exact type/ID bindings, tool names, expiry,
call counts, and byte budgets. Versioned serializers construct new allowlisted
hashes and reject secret-shaped artifact examples. Generic `as_json`, recursive
relationship traversal, listing from model tools, and arbitrary URLs are
forbidden.

### Credential theft

Provider, gateway-ingress, validator-ingress, gateway-to-MCP, and MCP-to-Hunter
credentials are separate environment variables, each declared only on the
service(s) that need it — never through a shared `env_file` — so `runner` and
`ansible-executor` never receive a provider key. Hunter stores only
service/grant digests. Logging filters cover authorization, provider bodies,
message bodies, drafts, validation details, and raw grants. The gateway's
`/turns` and the validator's `/validations` are reachable only from the
internal Rails-facing network and each require their own bearer token,
checked with a constant-time comparison, plus Host/Origin allowlisting; there
is no broker vhost or message-tracing surface to disable because there is no
broker.

### Confused deputy and token passthrough

User sessions and API bearer tokens are never forwarded. Browser endpoints
reject bearer auth. Machine endpoints reject sessions and ordinary API tokens.
MCP must present its dedicated reader identity plus the current turn grant;
Rails rechecks both for every operation. The MCP identity cannot authenticate
ordinary Hunter module routes.

### SSRF and egress escape

Provider base URLs and headers are not browser-configurable. The gateway knows
only the fixed OpenAI and Anthropic HTTPS endpoints and rejects redirects, but
it no longer sits behind an allowlisted egress proxy: squid and its
provider-domain allowlist were removed along with the RabbitMQ transport (see
the infrastructure-simplification delta). The gateway therefore has ordinary
outbound network reach from within its container; this is accepted as a
residual risk precisely because the gateway is also the component that parses
untrusted provider output. No other assistant service gained an Internet
route — `hunter-mcp` and `assistant-validator` remain confined to their
internal networks.

### Draft-to-execution escalation

Model-facing components cannot persist, send, schedule, cancel, or execute.
Whiterabbit validation fails closed without a command allowlist. Assistant
Ansible validation fails closed without a module allowlist and rejects local
execution, shell-like modules, roles, includes, imports, plugins, collections,
lookups, credential injection, and unsafe paths. A separate current-session
CSRF confirmation performs final validation and calls shared Control Center
persistence. It creates no job, run, or executor task.

### Resource exhaustion

Hard ceilings are five minutes, ten selected records, eight tool calls, 64 KiB
per result, and 256 KiB total tool output. Request, response, token, process,
CPU, memory, PID, concurrency, and validation time limits are enforced at each
boundary. Grant accounting uses database locks and pessimistic byte
reservations.

### Supply-chain and container compromise

Dependencies and images are version-locked, scanned, and accompanied by SBOMs.
Untrusted services use numeric non-root users, read-only filesystems, dropped
capabilities, no-new-privileges, service-specific syscall/MAC profiles, bounded
noexec tmpfs mounts, no host/Docker socket, no published ports, and minimal
network membership. A service compromise is still treated as an incident.

## Abuse cases

The adversarial suite must prove refusal of:

- requests to enumerate records or fetch an unselected ID
- URLs supplied as context or tool destinations
- unknown tools and extra JSON properties
- requests for prompts, keys, tokens, credentials, variables, or logs
- attempts to write, delete, send, schedule, cancel, or execute
- provider fallback or profile change during a conversation
- embedded private keys, bearer tokens, URL userinfo, and vault content
- oversized, recursive, malformed, deceptive, or partial provider output
- unsafe Ansible modules, local connections, roles/plugins/includes, and paths
- private, metadata, target, database, executor, and arbitrary Internet access

## Data retention and deletion

Conversation and draft bodies use non-deterministic Active Record Encryption.
Transcript retention defaults to seven days and is bounded to 1–30 days.
Immediate deletion removes conversation content transactionally. Body-free
security audits default to 90 days. Backups follow the deployment's independent
encrypted backup-retention policy; user-facing text must not claim that a live
deletion immediately erases historical backups or provider-side data.

## Verification

Run these gates from the repository root as their implementation lands:

```bash
cd web && bin/rails test
cd web && node --test test/javascript/*.mjs
cd assistant/mcp && go test -race ./...
cd assistant/gateway && go test -race ./...
cd assistant/validator && go test -race ./...
docker compose config
docker compose -f docker-compose.prod.yaml config
ops/assistant/verify_compose_security.sh
ops/assistant/test_network_denials.sh
ops/assistant/check_secret_leaks.sh
```

Production enablement also requires MCP conformance output, dependency and
image scans, SBOMs, a completed rotation drill, provider-retention approval,
and an independent security review with no unresolved critical/high findings.

## Change rule

Any new context type, MCP tool, provider feature, user role, write action, or
execution action requires an approved threat-model delta. It receives a
dedicated schema, authorization, UI disclosure, metadata audit, adversarial
tests, and—when effectful—an explicit human-approval design. Generic tools and
wildcard scopes are prohibited.
