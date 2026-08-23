# Assistant Codex MCP Boundary — Threat-Model Delta

**Status:** APPROVED FOR IMPLEMENTATION

**Date:** 2026-08-15

**2026-08-19 amendment:** The exact Hunter MCP catalog and this document's old
prohibition on dedicated Hunter run/send capabilities are superseded by
[`2026-08-19-assistant-mcp-administrator-proxy-design.md`](2026-08-19-assistant-mcp-administrator-proxy-design.md).
The exact pinned Codex-owned built-in set, provider isolation, prohibition on
generic capabilities, and requirement that every Hunter read/effect traverse
the reviewed Hunter MCP boundary remain in force.

**Approval record:** After the real pinned Codex CLI 0.144.4 capture showed
Codex-owned built-ins alongside a deferred Hunter MCP catalog, the operator
approved continuing with this boundary: Codex internal tools may remain, but
every current or future Hunter feature, including API-backed features, must be
reached through Hunter's MCP gateway. The operator then explicitly instructed
development to begin while they were unavailable. This approves this delta,
planning, implementation, testing, and the plan's commits. Production remains
disabled until the independent Assistant production checklist records evidence.

## Context and decision

The original direct-provider design required the model-visible tool set to equal
the reviewed Hunter MCP catalog. A process-level capture of the pinned official
`codex-cli 0.144.4` proved that this cannot be configured: the CLI exposes eight
Codex-owned built-ins and defers the allowed Hunter tools behind `tool_search`.

This delta replaces the model-visibility invariant with a capability-boundary
invariant:

- Hunter data and Hunter effects are available only through the authenticated
  `hunter` MCP server.
- Codex-owned internal tools are allowed only as the exact set captured and
  approved for the pinned CLI version.
- A Codex-owned tool must not receive a Hunter checkout, host path, datastore
  credential, Hunter API credential, Docker socket, unrestricted execution
  surface, or network route that bypasses MCP.
- A tool-set change, a new MCP server, or a new path into Hunter fails closed and
  requires review before the pinned version or configuration can change.

This does not approve a generic Hunter API, shell, filesystem, network, search,
credential, execution, send, schedule, delete, or run capability. Future Hunter
features may be added only as dedicated MCP tools or resources with closed
schemas, dedicated non-wildcard scopes, per-turn grants, authorization,
metadata-only audit coverage, UI disclosure, adversarial tests, and any human
approval required for their effects.

## Considered approaches

### Selected: exact pinned Codex built-in allowlist

Keep the official pinned CLI and accept only the exact observed Codex-owned
built-ins. Continue to verify the exact Hunter MCP catalog independently. This
preserves deterministic drift detection, avoids a new credential-bearing proxy,
and keeps Hunter authorization at the existing MCP boundary.

### Rejected: capability-category allowlist

Allowing any future tool described as planning, utility, or discovery would
make version drift subjective and could admit a newly effectful built-in without
review. Exact names and schemas are safer and simpler.

### Rejected: provider filtering proxy or Codex fork

A proxy would become a new provider-protocol, credential, network, and schema-
rewriting trust boundary. A fork would add a custom execution artifact and
supply-chain obligation. Neither is necessary once model visibility is
separated from access to Hunter.

## Approved tool boundary

For official `codex-cli 0.144.4` with model `gpt-5.4`, the exact approved
Codex-owned model-visible names are:

1. `list_mcp_resources`
2. `list_mcp_resource_templates`
3. `read_mcp_resource`
4. `update_plan`
5. `request_user_input`
6. `apply_patch`
7. `view_image`
8. `tool_search`

These names are approved only inside the isolated Codex runner and only under
the runtime restrictions in this document:

- The three MCP resource tools and `tool_search` may discover or invoke only the
  configured `hunter` MCP server. They do not create a second Hunter access path;
  the service bearer, per-turn grant, dedicated scopes, MCP authorization, and
  response projection remain authoritative.
- `update_plan` and `request_user_input` operate on the provider turn and do not
  receive a Hunter service route or credential.
- `apply_patch` is model-visible but is not approved as an effectful Hunter or
  host filesystem capability. The CLI remains configured with
  `sandbox_mode="read-only"`; the container root and empty working directory are
  read-only; and no Hunter checkout or host bind is mounted. An adversarial
  real-binary test must prove a requested patch cannot change the working
  directory before production evidence may pass.
- `view_image` has no Hunter or host image source because the runner receives no
  Hunter checkout, upload mount, transcript mount, or host bind. Adding any such
  source is a new Assistant context capability and requires another delta.

Shell/unified execution, web search, browser/computer use, apps/connectors,
plugins, skills, image generation, multi-agent delegation, permission tools,
generic credentials, and any additional built-in remain prohibited. The CLI
flags continue disabling every supported member of those families.

## Hunter MCP gateway

The runner configures exactly one MCP server named `hunter`. The service bearer
and per-turn grant are injected through narrowly named environment-backed
headers and never argv. `enabled_tools` is the intersection of the wrapper's
compiled reviewed catalog and the per-deployment request; it cannot add an
unknown tool.

The schema contract separately verifies that MCP initialization and discovery
return only the reviewed Hunter catalog. Codex 0.144.4 may defer that catalog
behind `tool_search`; deferral is acceptable. Missing Hunter tools, extra Hunter
tools, schema drift, another MCP server/source, a missing grant header, or a
direct Hunter/API route is not acceptable.

The current four authoring tools retain their existing explicit exceptions:
create and explicit edit only for Whiterabbit templates and Ansible playbooks,
dedicated non-wildcard scopes, mandatory fail-closed content validators,
create-only `Model.new`, edit by ID plus `expected_lock_version`, attribution,
metadata-only auditing, and the independent Control Center write toggle. No
delete, run, launch, send, or schedule tool is added.

## Isolation and credentials

`assistant-codex` remains a non-root, read-only container with `cap_drop: ALL`,
`no-new-privileges`, seccomp, bounded processes/CPU/memory, a bounded no-exec
temporary filesystem, no published port, and no host bind. Its working directory
is empty and immutable.

The only persistent mount is the dedicated `assistant_codex_home` credential
volume. It is mounted into no other service. Rails receives only the distinct
Codex ingress URL/token; Codex receives no Rails, PostgreSQL, MongoDB, RabbitMQ,
Control Center runner, Docker, or provider API-key credential.

Network membership remains exact:

- one internal Rails-to-Codex ingress network;
- one internal Codex-to-Hunter-MCP network; and
- one provider-egress network needed for ChatGPT subscription-backed Codex.

The provider-egress network is not a Hunter capability route. No Hunter web/API
service shares it. Adding an outbound URL tool or direct Hunter API destination
would be a new capability and is outside this delta.

## Closed schemas, authorization, and human effects

The browser and Rails contracts remain unchanged: conversation creation accepts
only `{"backend":"codex"}` or `{"backend":"claude_code"}`; turns are owner-bound,
rate-limited, backend-bound, and grant-bound; session and bearer authorization
remain separated; and the Assistant and Control Center write toggles revoke
their respective paths immediately.

Submitting a message is the human approval for one provider turn. Codex-owned
planning, interaction, or failed local utility calls do not authorize a Hunter
effect. A Hunter effect is authorized only when a dedicated MCP call also passes
its tool, scope, ownership, validation, and effect-approval policy.

## Audit and UI disclosure

Existing turn, dispatch, MCP tool, authoring, completion, cancellation, and
failure audits remain metadata-only. They include stable IDs, backend, operation,
outcome, and reason, and exclude prompts, replies, code, tool arguments, session
IDs, thread IDs, credentials, raw CLI events, and provider errors.

Settings must disclose that Codex runs in an isolated read-only service, that
Hunter data and actions are supplied only through the secured Hunter MCP
gateway, and that provider-owned internal utility/discovery tools may exist but
have no direct Hunter or host capability. The OpenAI chooser still approves only
conversation creation; message submission starts a turn.

## Adversarial outcomes

- A Hunter MCP call without the service bearer or valid turn grant is rejected
  by MCP with the existing stable authorization outcome and no effect.
- A Hunter tool outside the compiled allowlist is absent from discovery and
  rejected if named directly.
- A future Hunter API feature exposed directly to Codex, rather than through a
  dedicated MCP schema and scope, fails architecture review and production
  checklist review.
- A real-binary request to `apply_patch` cannot modify the empty working
  directory; any successful write fails the security gate.
- Shell, web, browser, computer, app, plugin, skill, image-generation,
  multi-agent, permission, or any ninth Codex-owned model-visible tool fails the
  exact pinned tool contract.
- A second MCP source, an extra/missing Hunter tool, or Hunter tool schema drift
  fails the contract.
- A host bind, Hunter checkout, shared credential volume, published runner port,
  datastore network, or Hunter API network fails Compose contract tests.
- Raw CLI events or provider output remain bounded and cannot enter API errors,
  logs, or audit metadata.

## Verification and production gate

Task 5's real-binary contract is revised to assert both halves of the boundary:

1. the top-level model-visible set equals the eight approved pinned Codex
   built-ins, with no ninth tool or schema drift; and
2. the only deferred MCP source is `hunter`, whose discoverable tool catalog and
   input schemas equal the reviewed grant catalog.

Focused Go tests must also demonstrate the read-only patch outcome. Compose
tests retain exact service, environment, mount, network, hardening, resource,
and no-provider-key assertions. Image builds and in-container real-binary checks
remain mandatory production evidence; a local skip due to a missing exact
binary or container runtime is not production evidence.

Production remains disabled until the Assistant production checklist records
the pinned version and digest, both real-binary contract results, image/runtime
hardening, network denials, login persistence, authenticated browser smoke,
stable errors, metadata-only audit canaries, and rollback evidence.
