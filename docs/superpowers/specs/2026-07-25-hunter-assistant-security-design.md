# Hunter Assistant Security Design

**Date:** 2026-07-25

**Status:** Approved

**Module:** Assistant (cross-cutting UI and `/api/v1/assistant` API)

## 1. Summary

Hunter will add an administrator-only LLM assistant presented as a chat bubble in
the bottom-right corner of the authenticated web application. The assistant can
use an approved OpenAI or Anthropic model to help author two artifact types in
its first release:

- Whiterabbit template drafts
- Ansible playbook drafts

The model-facing assistant path is an untrusted drafting system, not an
operator. The model, gateway, MCP broker, and assistant machine API cannot save,
modify, delete, send, schedule, or execute Hunter resources. They cannot
retrieve credentials or secret variables. A user must explicitly select every
Hunter record supplied as context, review the generated artifact and its
validation results, and confirm a separate Rails save action.

Two isolated services sit between the provider model and Hunter. A dedicated LLM
gateway calls the selected provider and acts as the MCP client. A dedicated MCP
broker, implemented in Go, exposes a small fixed catalog of read and validation
tools. The gateway has no Hunter API identity; the MCP broker is the only
assistant component with a narrowly scoped Hunter API identity.

Security is enforced by capabilities, schemas, authentication, network
boundaries, validation, and human confirmation. Prompts are behavioral guidance
and are not considered a security boundary.

## 2. Settled decisions

- V1 is available only to a cookie/session-authenticated user whose normalized
  username matches the deployment's configured `ADMIN_USERNAME`. Assistant
  browser endpoints do not accept API bearer tokens.
- The browser communicates only with Rails. It never receives provider or
  service credentials and never calls the gateway or MCP broker directly.
- The model receives only the user's message, authoring policy, and records the
  user explicitly selects after field-level sanitization.
- A conversation is pinned to one approved provider/model profile. Hunter never
  silently fails over to another provider.
- Conversations are encrypted in PostgreSQL. The default retention is seven
  days, configurable from one through thirty days, with immediate user deletion.
- Body-free security audit metadata is retained for ninety days by default.
- Provider, gateway-to-MCP, and MCP-to-Hunter credentials are distinct.
- Static service credentials are supplemented by a short-lived per-turn grant
  that limits tools, record identifiers, time, calls, and returned bytes.
- Secrets are initially delivered as file-mounted Docker Compose secrets. The
  Docker host and any external deployment-control administrators are part of the
  trusted computing base; compromise requires full credential rotation.
- `hunter-mcp` is a permanently running, dedicated Docker service implemented in
  Go using an exact pinned release of the official Tier 1 MCP Go SDK.
- No MCP tool in V1 performs a Hunter domain write or execution.
- Existing Whiterabbit and Ansible execution paths remain the only execution
  paths and are unreachable by the assistant.

## 3. Goals

- Provide useful, context-aware authoring without granting the model operational
  authority.
- Make every disclosure of Hunter data to a provider explicit and inspectable.
- Constrain compromise of the model, provider response, gateway, or prompt to a
  small, auditable read-only capability.
- Reuse Hunter's existing validation and domain-write paths instead of creating
  privileged assistant-only shortcuts.
- Preserve provider choice without letting a conversation cross provider data
  boundaries.
- Make service isolation, secret delivery, revocation, rate limiting, retention,
  and audit behavior testable.
- Establish a safe expansion pattern for future assistant capabilities.

## 4. Non-goals

- No autonomous operation, background agent loop, job launch, template send,
  Ansible execution, scheduling, retry, cancellation, or approval on the user's
  behalf.
- No model-driven search or browsing of Hunter data.
- No generic HTTP, GraphQL, SQL, MongoDB, filesystem, shell, browser, computer
  use, Docker, or arbitrary MCP proxy tool.
- No provider-hosted web search, code execution, Files API, vector store, remote
  MCP, computer use, or automatic cross-provider fallback.
- No access to SSH credentials, API tokens, secret variables, raw executor
  payloads, unredacted events, or container logs.
- No arbitrary provider base URL, request header, model, or proxy supplied from
  the browser.
- No multi-user RBAC implementation in V1. Records nevertheless retain explicit
  user ownership so later RBAC does not require a data-model rewrite.
- No claim that Docker isolates a remote model. Docker isolates Hunter's local
  gateway and broker; selected prompt data still leaves the deployment for the
  chosen provider.

## 5. Threat model and trusted computing base

### 5.1 Protected assets

- Hunter session and API credentials
- Provider API keys
- MCP service identities and turn grants
- Ansible credentials and encrypted variables
- Program, target, vulnerability, CVE, template, and playbook data
- Conversation content and generated drafts
- The integrity of saved automation artifacts
- The availability and auditability of Hunter's control plane

### 5.2 Threats in scope

- Malicious or compromised provider output
- Prompt injection embedded in a selected Hunter record or existing artifact
- A hostile user message attempting to expand tool access
- Malformed, oversized, recursive, or high-volume MCP requests and responses
- A compromised LLM gateway attempting direct Hunter access
- A compromised MCP broker attempting to exceed the current turn grant
- Token theft from logs, errors, process environments, or overly broad mounts
- Server-side request forgery and redirects through provider configuration
- Secret leakage in prompts, tool results, drafts, logs, and audit events
- Replay of grants or machine credentials
- Denial of service through token, tool-call, process, memory, or queue usage
- Supply-chain compromise of images and dependencies

### 5.3 Trust assumptions

Rails, PostgreSQL, the deployment's RabbitMQ control plane, and the Docker host
are trusted. Development and production use the project's Docker Compose
definitions without integrating an external deployment-control product into
Hunter. An administrator with Docker control can replace an image, enter a
container, mount host files, or create a privileged workload. File-mounted
secrets reduce routine exposure but do not protect against that administrator.
A Docker-host or external deployment-control compromise is a full-stack incident
requiring provider-key and service-token rotation.

OpenAI and Anthropic are external processors. Their contractual and configured
retention controls are part of profile approval, not assumptions made by Hunter.
The model itself, its output, selected Hunter content, the LLM gateway, and the
MCP broker are not trusted to authorize domain changes.

## 6. Architecture

```text
Authenticated browser
  | session cookie + CSRF
  v
Hunter Rails -------------------------------- PostgreSQL
  |                                              encrypted conversations,
  | dedicated assistant RabbitMQ vhost           grants, provider profiles,
  v                                              and body-free audits
LLM gateway container
  |                 \
  | MCP service      \ HTTPS through allowlisted egress proxy
  | identity +        \----> OpenAI or Anthropic API
  | turn grant
  v
Hunter MCP container (Go)
  | MCP-to-Hunter identity + same turn grant
  v
Dedicated `/api/v1/assistant` sanitized read/validation API

Separate confirmed-save path:

Browser review + CSRF confirmation
  -> ordinary Rails Control Center API/domain service
  -> final validation
  -> saved template or playbook
```

Rails dispatches turns and receives progress/results through a dedicated
RabbitMQ vhost rather than giving the LLM gateway a Hunter API route or token.
The vhost uses a dedicated account with configure permissions disabled and
publish/consume permissions restricted to assistant queue names. Turn messages
are non-durable, carry short-lived grants, and are not traced through RabbitMQ's
management features. A lost in-flight turn fails visibly and may be retried by
the user with a new grant.

The LLM gateway can reach only its assistant queues, the MCP broker, and the
provider egress proxy. The MCP broker can reach only the gateway-facing MCP
network and Hunter's assistant API. It has no provider or general Internet
route. Neither service can reach PostgreSQL, MongoDB, the Docker socket, the host
filesystem, Whiterabbit workers, the Ansible executor, or target networks.

## 7. Component responsibilities

### 7.1 Browser chat

- Renders the global bubble and docked chat panel only for the configured,
  session-authenticated `ADMIN_USERNAME` account.
- Starts a conversation using an enabled provider profile.
- Attaches and removes explicit context records through visible context chips.
- Shows which sanitized records will be sent before dispatch.
- Streams or polls turn progress through Rails.
- Renders provider text as escaped content, never trusted HTML.
- Renders generated artifacts as validated draft cards and diffs.
- Sends the separate CSRF-protected save confirmation.

### 7.2 Rails Assistant module

- Owns `/api/v1/assistant/...`, authentication, CSRF, profile selection,
  encrypted transcripts, retention, grants, dispatch, response ingestion,
  audits, rate limits, and the administrative kill switch.
- Rejects browser assistant requests authenticated by bearer token or by a user
  other than the normalized `ADMIN_USERNAME`; V1 does not infer admin status
  merely from possession of a valid Hunter account.
- Resolves selected records under the current user before issuing a turn grant.
- Defines versioned, field-allowlisted serializers for every supported context
  type.
- Independently enforces the grant on every MCP-originated data request.
- Revalidates a confirmed artifact and calls the existing Control Center domain
  service under `Current.user`.
- Never sends provider credentials to the browser, RabbitMQ, MCP, or database.

### 7.3 LLM gateway

- Loads provider credentials from files under `/run/secrets`.
- Consumes assistant turn jobs and publishes progress, result, and terminal-error
  events using its restricted RabbitMQ identity.
- Resolves a pinned provider adapter from the Rails-approved profile.
- Calls the provider only through the egress proxy.
- Acts as the MCP client and presents its MCP identity plus the opaque turn grant.
- Enforces provider response schemas, tool-call limits, deadlines, byte limits,
  and cancellation.
- Has no Hunter, database, Docker, executor, host, or target-network credential.
- Stores no persistent transcript or artifact.

The gateway implementation language is non-normative. Its container and public
contracts are normative, allowing its provider adapter internals to change
without changing the security boundary.

### 7.4 Hunter MCP broker

- Is a standalone Go service using a pinned official MCP SDK and protocol
  version.
- Authenticates the gateway service identity on every session/request.
- Introspects and caches the turn grant only until its expiry.
- Exposes only the fixed tools in this specification.
- Validates tool input and output against closed JSON schemas.
- Enforces tool, record, call, byte, and time restrictions before calling Rails.
- Calls only the dedicated Hunter assistant API using its own service identity
  plus the current grant.
- Applies a second output allowlist, size cap, and secret-pattern rejection.
- Emits metadata-only audit events and never logs request or result bodies.

### 7.5 Networkless Ansible draft validator

Ansible syntax checking that invokes Ansible runs in a separate restricted
validator worker, never in Rails, MCP, the gateway, or the production Ansible
executor. The validator has no network interface beyond its narrowly permitted
validation queue, no credentials, no inventory targets, no host mounts, and an
ephemeral workspace. Each validation uses a fresh subprocess with a deadline and
resource limits; the workspace is destroyed afterward. Static Rails validation
runs before a draft is eligible for this isolated syntax check.

The validator can parse and syntax-check a draft. It cannot execute a playbook,
load user-supplied collections/plugins/roles, contact an inventory host, or save
content.

## 8. Authentication and authorization

### 8.1 Service identities

Three credential classes remain separate:

1. Provider credentials are mounted only into the LLM gateway.
2. The gateway-to-MCP credential is mounted only into those two services.
3. The MCP-to-Hunter credential is mounted only into MCP and made verifiable by
   Rails as a dedicated assistant-reader machine identity.

The MCP identity is not a normal user `ApiToken`, a wildcard token, a
`control_center` token, or an executor `Runner`. It has access only to the
machine-facing assistant endpoints. Hunter stores only its digest where a
database record is used. Raw values are generated out of band, shown once, and
rotated independently.

Hunter user/session bearer tokens are never forwarded to the gateway or MCP.
This avoids token passthrough and preserves a clear audit boundary between the
human session and service identities.

### 8.2 Per-turn grants

After authorizing a user-selected context set, Rails creates one opaque,
cryptographically random grant and stores only its digest. The record binds:

- user ID and conversation ID
- turn ID
- pinned provider-profile ID
- allowed tool names
- allowed resource types and exact record IDs
- creation and expiration timestamps
- maximum tool calls
- per-call and cumulative returned-byte budgets
- used/revoked state

Conservative V1 defaults are a five-minute lifetime, ten selected records,
eight tool calls, 64 KiB per tool result, and 256 KiB of cumulative tool output.
Deployment configuration may lower these values but cannot exceed hard-coded
ceilings without a code change and review.

The raw grant is delivered only in the non-durable turn message and MCP requests.
It is filtered from all logging. MCP presents both service authentication and
the grant to Rails. Rails verifies both on every context or validation request;
MCP authorization alone is insufficient. A grant cannot authorize writes,
execution, searches, unlisted tools, or unlisted record IDs.

Grants are revoked when the turn ends, is canceled, or exceeds a limit. They are
not reused for retries or later conversation turns.

## 9. MCP V1 tool catalog

The MCP server returns a fixed tool list. Tools use closed input/output schemas
with unknown properties rejected.

### 9.1 `get_selected_context`

Accepts a resource type and ID present in the turn grant. Returns a versioned,
sanitized summary. V1 supported context types are program, target, CVE,
vulnerability, Whiterabbit template, and Ansible playbook.

It cannot list, search, paginate, follow relationships, or accept a URL. A
record that is missing, unauthorized, no longer within scope, too large, or
unsafe to disclose returns a stable error without fallback data.

### 9.2 `get_artifact_example`

Returns one explicitly selected Whiterabbit template or Ansible playbook after
artifact-specific sanitization. It refuses artifacts containing known embedded
credential fields, private-key material, access tokens, disallowed includes, or
content exceeding the grant budget. Refusal does not return the matching value.

### 9.3 `get_authoring_policy`

Returns versioned non-secret authoring policy for one artifact type: schema,
field limits, Whiterabbit command allowlist, supported operators, prohibited
Ansible constructs, and required validation rules. It does not reveal deployment
credentials, inventory secrets, worker details, or unapproved command paths.

### 9.4 `validate_whiterabbit_draft`

Accepts a structured Whiterabbit draft within existing model limits and invokes
the same no-shell, default-deny command and argument validation used by the
Control Center. It does not persist or send the draft.

### 9.5 `validate_ansible_draft`

Runs Rails static YAML/schema/policy checks first. If those pass, it queues an
isolated syntax check in the networkless validator. It supplies no inventory,
credential, variable set, collection, role, or plugin. It does not persist the
draft.

### 9.6 `get_validation_result`

Returns only a validation result bound to the current turn grant. Results contain
normalized codes, locations, and redacted messages. They never contain process
environment, filesystem paths outside a synthetic workspace label, command
lines, stack traces, or validator logs.

## 10. Data minimization and prompt-injection handling

Every context serializer uses an explicit per-type field allowlist. Generic
model serialization, model `as_json`, arbitrary API forwarding, and recursive
relationship traversal are prohibited.

The following are always excluded:

- session, API, runner, service, provider, and lease tokens
- SSH credentials, private keys, passwords, passphrases, and known-host secrets
- encrypted or decrypted Ansible variable values
- raw Ansible executor claim payloads
- unredacted run events and container/application logs
- database configuration, environment variables, and internal network details
- binary/file attachments and arbitrary URLs

Existing artifact examples receive structural field filtering plus bounded
secret-pattern detection. Detection is defense in depth, not a guarantee. A
positive match rejects the field or whole artifact; it is never replaced with a
placeholder that might still reveal useful secret structure.

Selected Hunter content and tool output are explicitly marked as untrusted data
in the provider request. They are never interpolated into system or developer
instructions. Tool output cannot change the tool catalog, grant, provider,
system prompt, or approval policy. The model may still follow a malicious
instruction embedded in data, so the design relies on its absent capabilities:
there is no secret, search, write, shell, filesystem, arbitrary network, or
execution tool to acquire.

Provider output must match either an assistant-message schema or one of the two
draft-envelope schemas. Unknown tool calls, extra fields, invalid nesting,
oversized strings, and unsupported artifact types terminate the turn safely.

## 11. Provider profiles and outbound controls

`Assistant::ProviderProfile` stores non-secret metadata:

- administrator-visible name
- provider enum (`openai` or `anthropic`)
- exact model identifier
- secret reference name, not a secret value
- enabled state
- input/output/tool-call limits
- approved retention posture and review timestamp
- creator and timestamps

Provider endpoints are compiled/configured from a fixed application allowlist.
Profiles cannot supply base URLs, arbitrary headers, redirects, or forward-proxy
settings. The gateway maps the secret reference to an explicitly mounted file;
unknown or absent references fail startup or reject the turn.

Outbound requests pass through a dedicated egress proxy that allows only
approved provider HTTPS hosts and ports. It rejects plaintext HTTP, redirects,
private/loopback/link-local/cloud-metadata destinations, oversized requests, and
invalid certificates. DNS and destination validation occur for each new
connection so a stale resolution cannot silently broaden access.

OpenAI requests set `store: false`. Profiles requiring zero retention are
enabled only after the deployment administrator confirms the organization and
chosen endpoint are eligible for Zero Data Retention. Anthropic profiles use the
direct Messages API and record whether the organization has a Zero Data
Retention agreement. Hunter's local deletion cannot promise deletion from a
provider; the UI states the approved provider retention posture before a new
conversation starts.

Provider-hosted web search, code execution, Files APIs, vector stores, background
mode, batches, memory, external/remote MCP, computer use, and automatic fallback
are disabled. Prompt caching is disabled in V1 to avoid endpoint-specific
retention ambiguity. The provider can request only the gateway's fixed local MCP
tools.

## 12. Chat and artifact-review experience

### 12.1 Chat shell

The collapsed state is a keyboard-accessible chat bubble fixed at the
bottom-right. Opening it shows a docked panel without navigating away from the
current Hunter department. Closing the panel preserves the active conversation.
The panel follows Hunter's existing dark visual language and remains usable on
small screens as a full-width or full-height overlay.

A new conversation begins with an approved provider-profile selector and a
plain-language data-retention notice. The provider/model cannot change after the
first turn. Context attachment controls expose the current page record where
applicable and an explicit picker for supported types. Each attachment appears
as a removable chip and a disclosure preview before sending.

### 12.2 Draft cards

A valid artifact envelope renders as a draft card containing:

- artifact type and proposed name
- escaped, syntax-highlighted source
- validation state, stable errors, and warnings
- a diff when an existing artifact is the intended destination
- copy and open-in-editor actions
- an explicit `Save draft` action only after required validation passes

There are no run, send, schedule, credential, or secret-variable controls in the
chat. An incomplete stream is ordinary assistant text and never a savable draft.

### 12.3 Confirmed save

Selecting `Save draft` opens a confirmation showing the complete destination,
artifact content or diff, validation version, and consequences. Confirmation is
a new CSRF-protected browser request authenticated by the current Rails session.
The browser does not replay a model-issued credential.

Rails checks ownership/authorization, reloads the destination, detects stale
updates, re-runs all current validation, and calls the existing template or
playbook domain service. The assistant API and MCP are not involved. A successful
save records the resulting artifact ID and content hash in the security audit.
There is no chained execution or send action.

## 13. Persistence and retention

Conversation and message bodies use non-deterministic Active Record Encryption.
Models include explicit user ownership, provider-profile binding, lifecycle
state, expiration, timestamps, and per-turn provider/tool usage metadata.
Provider keys, service tokens, raw grants, tool-result bodies, and validator logs
are never stored in conversation rows.

The default transcript expiration is seven days. An administrator may configure
one through thirty days. A user deletion immediately makes the conversation
unavailable and deletes its messages and drafts in the same database transaction;
background cleanup removes expired rows on a recurring schedule. Backups follow
the deployment's documented backup retention and encryption policy, so the UI
does not claim that a deletion instantly erases historical backups.

Security audits are stored separately and omit prompt, response, draft, and tool
result bodies. The default retention is ninety days. An event may contain:

- timestamp, correlation ID, user, conversation, and turn identifiers
- provider profile and exact model
- tool name, authorized resource type/ID reference, result status, and byte count
- grant creation, rejection, exhaustion, revocation, and expiry
- provider latency and token accounting
- validation version, outcome, and normalized error codes
- draft content hash
- confirmed-save target type, ID, and resulting content hash

Authorization headers, raw tokens/grants, secret-reference paths, request bodies,
provider bodies, tool bodies, generated source, and validation stderr are
forbidden in logs and audits.

## 14. Container and deployment hardening

The gateway, MCP broker, validator, and egress proxy are dedicated services with
no published host ports. Images use multi-stage builds and minimal non-root
runtime stages. The project supplies separate local-development and production
Compose definitions. Any infrastructure service used to deploy the production
definition remains external to Hunter: there is no application integration,
runtime dependency, or project-specific configuration for it. Production
requirements include:

- fixed numeric non-root UID/GID
- read-only root filesystem
- all Linux capabilities dropped
- `no-new-privileges`
- default-deny custom seccomp and AppArmor/SELinux policy where supported
- bounded `tmpfs` with `noexec,nosuid,nodev`
- explicit CPU, memory, PID, request-body, response-body, and concurrency limits
- no host bind mounts except deployment-managed read-only secret files
- no Docker socket, devices, privileged mode, host PID, host IPC, or host network
- internal Docker networks with only required service membership
- application-level outbound destination checks in addition to network policy
- health endpoints that disclose no configuration or dependency details
- dependency locks, reproducible builds, SBOMs, vulnerability scanning, and image
  digest pinning in production

Provider and service secrets originate outside the repository and image. Compose
grants each secret only to the services that require it and mounts it under
`/run/secrets`. Processes read secrets without printing them. Rotation replaces
the source and recreates only the affected service.

## 15. Failure handling and kill switch

- Provider timeout, rejection, invalid output, quota exhaustion, or HTTP failure
  ends the turn with a stable error. Hunter never switches provider automatically.
- MCP unavailability or invalid tool output ends tool use. The gateway cannot
  fabricate a tool result and continue as though it came from Hunter.
- Missing, expired, replayed, revoked, or exhausted grants fail closed and do
  not cause automatic grant renewal.
- Queue loss marks the turn interrupted. A retry creates a new turn and grant.
- Context records removed after grant creation return `not_found`; authorization
  changes return `forbidden`; neither response leaks the former content.
- An incomplete provider stream is not parsed or saved as an artifact.
- Static or isolated validation failure keeps the content reviewable but disables
  saving until the model or user produces a valid revision.
- A stale target artifact prevents update and requires a new diff/review.
- Transcript or audit persistence failure prevents dispatch or confirmation;
  security-relevant work never proceeds without its required record.

An administrator kill switch disables new turn dispatch and revokes active
grants and assistant service identities without affecting ordinary Hunter APIs,
Control Center authoring, or existing executors. Provider-key compromise,
service-token compromise, Docker/deployment-control compromise, or unexplained
assistant data access triggers the kill switch and credential-rotation runbook.

## 16. Testing and security verification

### 16.1 Rails tests

- Exact `ADMIN_USERNAME` session authorization, bearer-token rejection, CSRF,
  ownership, profile pinning, and disabled-profile behavior
- Grant creation, digest-only storage, exact record binding, budgets, expiry,
  revocation, replay, and concurrent-call handling
- Field-level serializers and explicit forbidden-field coverage for every
  supported context type
- Encrypted transcript storage, immediate deletion, recurring purge, and
  configured retention bounds
- Metadata-only audit allowlists and log filtering
- Final validation, stale-update handling, and confirmed save through existing
  domain services
- Proof that MCP machine authentication cannot reach ordinary module routes

### 16.2 MCP and gateway tests

- Official MCP conformance suite against the pinned protocol version
- Closed-schema input/output tests, unknown tools/properties, invalid IDs, and
  oversized/recursive JSON
- Tool and byte budgets, deadlines, cancellation, and concurrency limits
- Service authentication plus Rails grant enforcement on every tool
- Provider adapter contract tests with mock servers; no real secrets in CI
- Provider profile endpoint allowlist, redirect, DNS, private-address, and TLS
  failure tests
- Structured draft-envelope parsing and refusal of partial or extra content
- Fuzzing of JSON-RPC framing, schemas, provider streams, and redaction paths

### 16.3 Adversarial fixtures

- Prompt injection in every selected resource type
- Instructions pretending to be system or developer messages
- Requests to enumerate records, fetch arbitrary IDs/URLs, reveal prompts or
  tokens, invoke unknown tools, write, send, schedule, or execute
- Existing artifacts containing private keys, bearer tokens, shell metacharacters,
  unsafe Ansible constructs, or oversized/deep YAML
- Provider output containing HTML/script content, control characters, terminal
  escapes, malformed Unicode, and deceptive validation claims

### 16.4 Deployment verification

Automated tests from inside each service prove denied network paths: the gateway
cannot reach Rails module APIs, databases, executors, target networks, or cloud
metadata; MCP cannot reach providers or the public Internet; the validator
cannot reach any network target. Tests also verify no published ports, no Docker
socket, non-root execution, read-only roots, capability drops, resource limits,
and unavailable secret mounts in unrelated services.

CI produces dependency audit results, container vulnerability scans, SBOMs, and
fully resolved security reviews for both the local-development and production
Compose definitions. A production enablement checklist requires an independent
security review and remediation of critical/high findings before the feature
flag is enabled.

## 17. Delivery sequence

1. Produce a repository threat model, data-flow inventory, abuse cases, and
   incident/rotation runbook.
2. Add machine identities, secret mounts, isolated networks, hardened service
   shells, mock provider/queue contracts, and the global kill switch.
3. Add encrypted conversation persistence, retention jobs, provider-profile
   metadata, and the authenticated chat shell with no model or tools enabled.
4. Add grants and the dedicated read-only Rails assistant endpoints with field
   sanitization and negative authorization tests.
5. Implement and conformance-test the dedicated Go MCP broker.
6. Add the LLM gateway, egress proxy, pinned OpenAI/Anthropic adapters, and mock
   end-to-end turns while provider-hosted tools remain disabled.
7. Add structured Whiterabbit and Ansible drafts plus static validation, with no
   save action.
8. Add the networkless Ansible syntax validator and adversarial validation suite.
9. Add draft cards, diffs, explicit confirmation, and final save through existing
   Rails domain services.
10. Complete network-denial tests, image/SBOM scans, external security review,
    production configuration review, key rotation drill, and staged feature-flag
    enablement.

Each stage is deployable with later capabilities disabled. A failed security
gate blocks the next stage rather than being accepted as follow-up debt.

## 18. Future expansion rule

Adding a context type, tool, provider feature, write action, execution action, or
additional user role requires a new threat-model delta and approved design. A
new capability is never added by widening a generic tool or granting `*` scope.
It receives a dedicated schema, service authorization, UI disclosure, audit
events, adversarial tests, and, for any effectful action, an explicit human
approval design.

## 19. References

- [MCP security best practices](https://modelcontextprotocol.io/docs/tutorials/security/security_best_practices)
- [MCP authorization](https://modelcontextprotocol.io/specification/draft/basic/authorization)
- [Official MCP Go SDK](https://github.com/modelcontextprotocol/go-sdk)
- [MCP SDK tiering](https://modelcontextprotocol.io/community/sdk-tiers)
- [Docker Compose secrets](https://docs.docker.com/compose/how-tos/use-secrets/)
- [Docker rootless mode](https://docs.docker.com/engine/security/rootless/)
- [Docker seccomp profiles](https://docs.docker.com/engine/security/seccomp/)
- [Docker Engine security](https://docs.docker.com/engine/security/)
- [OpenAI API data controls](https://platform.openai.com/docs/models/default-usage-policies-by-endpoint)
- [Anthropic commercial API retention](https://privacy.claude.com/en/articles/7996866-how-long-do-you-store-my-organization-s-data)
