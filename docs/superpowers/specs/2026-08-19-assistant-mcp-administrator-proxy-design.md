# Hunter Assistant MCP Administrator Proxy — Design & Threat-Model Delta

**Status:** APPROVED BY OPERATOR

**Date:** 2026-08-19

**Approval record:** The operator rejected the previous narrow interpretation of
“full access” and approved a broader model: submitting an Assistant message as
the configured Hunter administrator authorizes the model to perform the
non-secret, non-delete operational work requested in that message. The model
must use Hunter MCP for every Hunter read and effect. The operator approved the
reviewed capability-catalog architecture, the route-by-route API classification,
human-only security/governance controls, workflow-scale budgets, metadata-only
auditing, phased delivery, and the acceptance requirements in this document.

## Supersession

This document supersedes the capability boundary in
`2026-07-30-assistant-mcp-full-access-authoring-design.md`. That design remains
historical evidence for the first read/create/edit implementation, but its
prohibitions on job submission, run launch/cancellation, broader non-secret
operational writes, and workflow-scale MCP use no longer describe the approved
target.

It also supersedes the old exact Hunter `CHAT_TOOLS` catalog and the old
no-run/no-send Hunter MCP statements repeated in
`2026-08-13-assistant-direct-provider-selection-design.md` and
`2026-08-15-assistant-codex-mcp-boundary-design.md`. Their provider selection,
credential isolation, runner hardening, exact Codex-owned built-in pin, and
MCP-only Hunter access requirements remain authoritative.

This delta does not weaken the provider isolation approved by the direct Claude
Code and Codex designs. Both provider processes still reach Hunter only through
the single authenticated `hunter` MCP server. Neither process receives a Hunter
API token, database credential, datastore connection, Docker socket, generic
network client, shell, filesystem tool, or worker identity.

## Goal

Make Hunter Assistant capable of administering Hunter's ordinary operational
workflow on behalf of the configured human administrator. It must be able to
find and analyze Hunter data, create and update non-secret operational records,
resolve target sets, submit and monitor Whiterabbit jobs, operate non-secret
Ansible resources, and launch/cancel/inspect Ansible work.

MCP is the sole capability proxy. Adding, removing, or disabling a dedicated MCP
capability is how Hunter expands or limits the Assistant. There is no generic
“call the Hunter API” escape hatch.

The permanent exclusions are:

- secret values or secret-bearing input;
- destructive record deletion;
- Assistant/security/governance administration;
- API-token, user, role, provider-authentication, or capability administration;
- runner and executor machine-identity callbacks; and
- generic HTTP, network, shell, filesystem, database, credential, send,
  scheduling, or execution tools.

“Generic” is the key distinction in the last item. Dedicated tools such as
`submit_whiterabbit_job` and `launch_ansible_run_group` are approved; a generic
`execute`, `send`, `request`, or `run_command` tool is not.

## Confirmed current failures

The live conversation captured in `tmp/images/ai-assistance-prompts.png`
demonstrates two separate root causes:

1. Hunter advertises only reads plus template/playbook create/edit. There is no
   MCP tool, scope, or Assistant machine route for submitting a Whiterabbit job,
   so the refusal to send the job is deliberate under the old design.
2. A turn grant is hard-capped at eight MCP calls while `list_targets` omits
   technology detail. Analyzing 57 targets therefore encourages one
   `get_target` call per item; the ninth call becomes `turn_grant_rejected`.
   Claude then incorrectly suggests that the user can “re-approve” calls even
   though Hunter has no re-approval mechanism.

The new design fixes both the capability gap and the workflow-scale failure. It
does not paper over them with prompt wording.

## Selected architecture

### Reviewed capability catalog

A versioned catalog is the authoritative inventory of Assistant-accessible
Hunter capabilities. Every entry contains:

- exact MCP tool name;
- module and operation name;
- effect class (`read`, `analyze`, `create`, `update`, `validate`, `export`,
  `execute`, `cancel`, or `restore`);
- exact non-wildcard authorization scope;
- closed input and output schema versions;
- Assistant machine route and HTTP method;
- corresponding administrator-facing API operation or domain service;
- feature gate;
- per-turn and hourly rate profile;
- result-byte profile;
- idempotency and optimistic-locking policy;
- secret-input and secret-output policy;
- audit event and safe target metadata; and
- rollout state.

The catalog is reviewed metadata, not a generic dispatcher. Go still registers
module-specific tools with module-specific decode/build/validate code. Rails
still exposes module-specific machine controllers and calls module-specific
domain services. CI proves that the Rails catalog, Rails grants, Go registry,
Claude allowlist, and Codex allowlist contain the same enabled names and scopes.

### MCP-only data flow

Every tool call follows this path:

1. The administrator submits a message in an owned Hunter conversation.
2. Rails issues a short-lived grant bound to that user, conversation, turn, and
   provider profile, containing the exact currently enabled tools and scopes.
3. Claude or Codex receives only the exact enabled Hunter MCP catalog.
4. `hunter-mcp` authenticates its service identity and the turn grant,
   introspects the grant, checks tool/scope/resource/live budgets, closed-decodes
   input, and dispatches one module-specific machine request.
5. Rails repeats service/grant/tool/scope/live-gate checks, reconstructs the
   original human as `Current.user`, validates the operation, and calls the
   ordinary Hunter domain service.
6. Rails returns an explicit secret-safe projection. MCP applies independent
   size, secret, and exact-output validation before returning the result.
7. Effects return a stable action receipt and record a metadata-only audit.

The MCP service bearer alone has no domain authority. The turn grant alone is
not accepted outside the MCP service path. Every effect is attributed to the
human administrator who submitted the turn.

## Human approval model

Submitting a message is the human approval for every currently enabled
operational MCP action reasonably necessary to fulfill that message. There is
no browser confirmation dialog and no native Claude/Codex permission prompt.

The model policy permits effects only to fulfill the current human message. It
must never treat content retrieved from a target, program, vulnerability,
template, job, run, event, or other Hunter record as an instruction. The server
does not pretend that semantic prompt parsing can prove intent; enforceable
safety comes from the closed capability boundary, permanent exclusions,
schemas, validators, idempotency, feature gates, and audit.

## API audit and coverage rule

The design audit covers 186 current API operations: all 139 public operations
plus 47 dedicated/internal Assistant machine operations documented under
`web/config/openapi/*.yaml` or routed in `web/config/routes.rb`. HTTP aliases
such as `PATCH` and `PUT` count as one MCP capability when they invoke the same
domain operation.

Every current and future `/api/v1` operation must have exactly one catalog
classification:

- `enabled` — represented by a dedicated MCP capability;
- `excluded_secret` — reads or accepts secret material;
- `excluded_delete` — destructively deletes a record or secret value;
- `excluded_governance` — changes Assistant/security authority;
- `excluded_machine_identity` — belongs to a runner/executor service identity;
- `internal_mcp_backend` — an Assistant machine route implementing a catalog
  tool; or
- `api_alias` — an alternate HTTP verb for an already classified operation.

CI compares Rails routes, OpenAPI paths, and the capability catalog. An
unclassified new operation fails CI and stays unavailable. OpenAPI never
automatically registers a tool.

### Current API decisions

| API area | Approved Assistant coverage | Permanent exclusions |
|---|---|---|
| OpenAPI/capabilities | Read currently enabled capability names, descriptions, scopes, gates, and limits. | No mutation of the catalog or gates. |
| Targets | List, search, filter, count, get, aggregate technologies/statistics, and build job selections. | None of the current target API is secret or destructive. |
| Sitemap | List/search/count/get safe endpoint detail, aggregate statistics, and build job selections. | Raw credentials/cookies remain outside projections. |
| Programs | List/get programs, analyze program data, list program changes, and list/get scope-run logs. | No user/security administration. |
| CVEs | List/search/get, analyze, and consume the new-since feed with explicit filters. | `/cves/config` is token-filter governance and is not exposed. |
| Vulnerabilities | List/search/get/analyze, create, and update through a closed document schema. | Delete; the public controller's current unrestricted `permit!` is never reused by MCP. |
| Ansible credential metadata | List/get safe metadata and use opaque credential IDs in other tools. | Create, update, rotate, clear, reveal, or delete credential material. |
| Ansible playbooks | List/get/analyze, create/update, validate, and export. | Delete. |
| Ansible inventories | List/get, create/update, validate, syntax-check, scan and confirm host keys, test connectivity, and poll safe utility-task results. | Delete; secret credential material and raw private material. |
| Ansible variable sets | List/get, create/update sets, and create/update explicitly non-secret typed variables. | Delete and every secret-variable create/update/value operation. |
| Ansible execution | List/get/analyze run groups and runs, launch, cancel, list redacted events, and read executor health. | Executor claim/start/heartbeat/event-ingestion/result callbacks. |
| Whiterabbit templates | List/get/analyze, create/update, validate structured content, and validate YAML. | Delete. |
| Whiterabbit jobs | Resolve selections, submit jobs, list/get/analyze history and output, and read health/statistics. | Runner claim/result callbacks. |
| Assistant API | Existing machine routes back MCP tools internally. | Conversations, drafts, provider profiles, settings, grants, and other Assistant self-administration are not MCP tools. |

Reversible operational transitions such as cancel, restore, or untrash are not
record deletion. If an existing browser route uses HTTP `DELETE` to express a
reversible transition, the Assistant receives a separately named non-DELETE
machine action such as `restore_program`; it never receives that browser route.

## Approved tool families

The catalog contains exact dedicated tools. The implementation plan may split a
family across module packages, but it may not replace these families with a
generic tool.

| Family | Dedicated capabilities |
|---|---|
| Catalog | `list_hunter_capabilities` |
| Targets | `list_targets`, `get_target`, `analyze_targets` |
| Sitemap | `list_endpoints`, `get_endpoint`, `analyze_endpoints` |
| Programs | `list_programs`, `get_program`, `analyze_programs`, `list_program_changes`, `list_scope_runs`, `get_scope_run` |
| CVEs | `list_cves`, `get_cve`, `list_new_cves`, `analyze_cves` |
| Vulnerabilities | `list_vulnerabilities`, `get_vulnerability`, `analyze_vulnerabilities`, `create_vulnerability`, `update_vulnerability` |
| Whiterabbit templates | `list_templates`, `get_template`, `analyze_templates`, `validate_whiterabbit_template`, `validate_whiterabbit_yaml`, `create_whiterabbit_template`, `edit_whiterabbit_template` |
| Whiterabbit jobs | `list_jobs`, `get_job`, `analyze_jobs`, `resolve_job_targets`, `submit_whiterabbit_job`, `get_control_center_health`, `get_control_center_stats` |
| Ansible credential metadata | `list_ansible_credential_metadata`, `get_ansible_credential_metadata` |
| Ansible playbooks | `list_playbooks`, `get_playbook`, `analyze_playbooks`, `validate_ansible_playbook`, `export_ansible_playbooks`, `create_ansible_playbook`, `edit_ansible_playbook` |
| Ansible inventories | `list_ansible_inventories`, `get_ansible_inventory`, `validate_ansible_inventory`, `create_ansible_inventory`, `edit_ansible_inventory`, `queue_inventory_syntax_check`, `queue_host_key_scan`, `confirm_inventory_host_keys`, `queue_inventory_connectivity_test`, `get_inventory_utility_task` |
| Ansible variables | `list_ansible_variable_sets`, `get_ansible_variable_set`, `create_ansible_variable_set`, `edit_ansible_variable_set`, `create_nonsecret_ansible_variable`, `edit_nonsecret_ansible_variable` |
| Ansible execution | `list_run_groups`, `get_run_group`, `analyze_ansible_runs`, `launch_ansible_run_group`, `cancel_ansible_run_group`, `get_run`, `cancel_ansible_run`, `list_run_events`, `get_ansible_executor_health` |

The catalog may add another dedicated analysis or bulk tool when it reduces
model calls without expanding the underlying data/effect boundary. Any new
context type or effect still requires its own approved delta under `AGENTS.md`.

### Export behavior

`export_ansible_playbooks` must not hand a filesystem to the model. It creates a
bounded, user-owned, short-lived download artifact through a dedicated Rails
service and returns only an action receipt containing safe artifact metadata and
the browser-download reference. Archive bytes do not enter the model, audit, or
logs. Expiration cleanup is system retention, not an LLM delete capability.

## Scopes and feature gates

Every effectful tool has its own narrowly named non-wildcard scope. Read tools
may share one module-read scope only when they expose the same reviewed data
class. A grant contains both the exact tool and the exact required scope; one
without the other authorizes nothing.

All approved operational capabilities default on for the configured Assistant
administrator once their rollout state is production-ready. Human-only settings
can disable:

- one exact tool;
- one effect class; or
- an entire module.

Group controls are administrative convenience only. Rails expands them to the
exact effective tool/scope set. Machine endpoints recheck the live gate so a
human disable immediately blocks an already-issued grant. The LLM may read its
effective capabilities but receives no capability-setting tool.

The global Assistant kill switch remains authoritative.

## Permanent deletion boundary

The catalog validator rejects any tool entry that:

- uses HTTP `DELETE`;
- maps to a Rails `destroy` action;
- declares a delete/purge/destroy effect;
- invokes a known deletion service; or
- accepts a generic method/path/service selector.

MCP and provider catalog tests also reject tool names containing a destructive
operation unless the catalog explicitly classifies the action as reversible
`restore` or `cancel` and proves it cannot delete a record.

The LLM cannot delete templates, playbooks, inventories, variable sets,
variables, credentials, vulnerabilities, conversations, providers, jobs, runs,
users, tokens, or any other Hunter record.

## Permanent secret boundary

Secret exclusion applies to both output and input. The Assistant cannot receive
a secret from Hunter and cannot be used as a path for entering or rotating one.

- Credential tools expose identifiers, names, auth type, username, public
  fingerprint, configured/not-configured flags, and safe timestamps only.
- Secret Ansible variables return `value: null` plus safe name/type/configured
  metadata. Create/edit tools reject `secret: true`, attempts to change a secret
  variable, and secret-shaped keys.
- Inventory/run/playbook/template projections omit encrypted payloads,
  passwords, private keys, tokens, cookies, authorization headers, raw known
  hosts, lease material, runner identities, and credentials.
- Evidence, job output, and run events pass field-aware redaction before the
  final cross-module checker.
- Closed schemas reject unknown keys. Generic nested maps are not accepted
  unless their key/value grammar and bounds are explicitly reviewed.
- Secret scanners run on normalized input, Rails output, and MCP output.

If the administrator pastes a secret into chat, that does not authorize a tool
to persist it. Secret-bearing tool schemas do not exist. UI guidance tells the
administrator to use the human-only credential/settings interface instead.

## Security and governance control plane

The LLM receives no MCP operation for:

- enabling/disabling tools or changing scopes, budgets, validators, or audit;
- Assistant settings, provider profiles, provider authentication, or retention;
- users, roles, sessions, API tokens, saved API-token filters, or service
  identities;
- runner/executor claim, lease, heartbeat, start, event ingestion, or result
  submission; or
- generic network, API, shell, filesystem, database, credential, send,
  scheduling, or execution access.

This boundary ensures MCP remains the administrator's control proxy instead of
something the model can reconfigure from inside a conversation.

## Validation, concurrency, and idempotency

Existing domain validators remain mandatory. Assistant routes may add stricter
input constraints but may never bypass the ordinary validation/persistence
service.

- Artifact and resource updates require ID plus `expected_lock_version` where
  the model is backed by a lockable PostgreSQL record. The complete merged
  record is revalidated before saving.
- Mongo vulnerability updates use a reviewed closed field set and a concurrency
  precondition derived from the record's safe version/update marker. MCP never
  forwards the public controller's schemaless `permit!` body.
- Creates and executions use an idempotency key derived from the turn, tool, and
  canonical normalized input. Repeating an identical call in one turn returns
  the original result.
- Intentionally repeating the same operation requires a new explicit operation
  discriminator or a new turn; retries cannot silently duplicate work.
- Job submission keeps the existing user-bound idempotency behavior.
- Cancel operations are idempotent or return a stable state conflict.

## Workflow-scale budgets

The old hard maximum of eight calls is retired.

- Default per-turn tool-call budget: 64.
- Human-configurable hard ceiling: 128.
- Default create/update effect budget: 32 per turn and 120 per hour.
- Hard create/update ceiling: 64 per turn and 240 per hour.
- Default job/run launch budget: 16 per turn and 60 per hour.
- Hard launch ceiling: 32 per turn and 120 per hour.
- Maximum grant lifetime: the provider turn deadline plus a short completion
  window, never more than 30 minutes.
- Maximum encoded result: 1 MiB per call unless the catalog sets a lower bound.
- Maximum returned result bytes per turn: 16 MiB.

Only the human governance UI may change values within hard ceilings. A tool can
declare a stricter profile.

Bulk and aggregate tools are preferred over consuming the larger budget:

- one target-selection descriptor may represent thousands of targets;
- analysis tools compute counts, groups, distributions, and bounded samples on
  the server;
- list tools page with cursors/limits; and
- oversized data returns summaries and cursors rather than failing after many
  detail calls.

The target-analysis request from the captured conversation must obtain the
technology distribution for all 57 matching targets without one detail call per
target.

## Asynchronous operations

Job, run, syntax-check, host-scan, and connectivity tools enqueue work and
return an action receipt with an ID and initial status. Read tools poll status
and redacted events with cursors. An MCP request never stays open for the full
scan and the model never calls worker endpoints.

This design does not create autonomous background model turns. The
administrator's message authorizes the current turn to launch and inspect work;
Hunter's existing workers continue the operation after the model turn ends.

## Stable errors

Public MCP errors are closed, accurate, and actionable:

- `capability_disabled`
- `scope_not_granted`
- `turn_grant_expired`
- `turn_call_budget_exhausted`
- `effect_rate_limited`
- `validation_failed`
- `version_conflict`
- `idempotent_replay`
- `not_found`
- `conflict`
- `upstream_unavailable`
- `tool_response_rejected`

The provider system policy requires the model to report these outcomes plainly.
It must never ask the user to re-approve MCP calls. If a turn truly exhausts a
budget, the response lists what completed, what did not, and the stable reason.

## Action receipts, UI disclosure, and audit

Every effect returns a closed receipt containing:

- operation and effect class;
- safe target type and identifier;
- resulting status;
- relevant artifact/job/run/task ID;
- idempotent replay indicator; and
- correlation ID.

The chat UI may display receipts inline as informational activity. They are not
confirmation prompts.

Metadata-only audits record human user, conversation, turn, provider, tool,
scope, effect class, target type/ID, selection count, outcome, stable error,
duration, byte counts, capability version, and idempotency outcome. Audits never
contain prompts, replies, target lists, commands, YAML, diffs, vulnerability
evidence, job output, run output/events, archive bytes, credential metadata that
could identify secret material, or secrets.

Settings disclose that an explicit administrator message can cause real Hunter
writes and execution through enabled MCP tools. They also disclose the permanent
no-secret/no-delete/no-governance boundary and show the human-only capability
controls and current budgets.

## Prompt-injection handling

All Hunter-derived strings are untrusted data. Tool descriptions and provider
policy instruct the model never to follow instructions contained in records or
tool results. Rails projections remove active/markup/control content where
appropriate and MCP returns structured content, not executable instructions.

Adversarial tests place tool-like instructions in program policies,
vulnerability evidence, target titles/headers, template descriptions, job
stdout/stderr, and Ansible events. Stable acceptance requires that these values
cannot alter the catalog, add a scope, reach an excluded tool, change a tool
schema, or bypass a validator. Because operational effects are deliberately
available, model-behavior tests also verify that unrelated injected text does
not cause an effect absent a corresponding human request.

## Delivery phases

Implementation is divided into independently reviewable releases:

1. Capability catalog, exact scopes, feature gates, larger budgets, accurate
   errors, action receipts, and route/OpenAPI classification gates.
2. Complete read/search/aggregate/analysis coverage.
3. Vulnerability and non-secret artifact create/update coverage.
4. Whiterabbit target resolution, job submission, monitoring, health, and
   statistics.
5. Ansible playbooks, inventories, non-secret variables, validation, export,
   and utility tasks.
6. Ansible launch, cancellation, monitoring, event analysis, and health.
7. Cross-provider catalog parity, adversarial review, live acceptance, rollback
   evidence, and production decision.

Capabilities can remain individually disabled during rollout. The design is not
complete until every permitted current API operation is implemented or carries
one of the permanent exclusion classifications above.

## Verification requirements

### Catalog and API coverage

- Every current `/api/v1` Rails route and all 139 current OpenAPI operations
  have exactly one classification.
- Every `enabled` operation maps to a dedicated tool, exact scope, live gate,
  closed schemas, safe projection, budget, and audit event.
- PATCH/PUT aliases map to the same capability and cannot double authority.
- A new or changed API route fails CI until classified.
- OpenAPI cannot auto-register a tool.

### Authorization and revocation

- Service credential alone, turn grant alone, wrong user/turn/provider, wrong
  tool, wrong scope, expired grant, and disabled live gate all fail closed.
- Claude and Codex expose exactly the same enabled Hunter catalog.
- Group toggles expand only to exact reviewed tools/scopes.
- Disabling a tool blocks an already-issued grant immediately.
- No wildcard tool or scope is accepted.

### Secrets, deletion, and governance

- No tool can issue HTTP DELETE, call a destroy action/service, or select an
  arbitrary route/method/service.
- Secret fixture values never appear in input echoes, outputs, errors, logs,
  audits, receipts, or provider-visible context.
- Credential and secret-variable values remain inaccessible.
- Assistant/provider/user/role/token/capability settings and worker callbacks
  have no MCP tool.
- Built-in shell, filesystem, network, browser, apps, plugins, skills,
  multi-agent, and permission-request tools remain unavailable to provider
  runners.

### Effects and workflow

- Creates/updates validate complete normalized state and attribute the human.
- Stale updates change nothing.
- Duplicate creates/launches return the original effect and do not enqueue
  twice.
- Rate and byte reservations release correctly on all stable failure paths.
- One filtered selection submits work for the complete resolved target set.
- Long-running tools return promptly and status/event polling is cursor-bound.

### Live acceptance

A production candidate must demonstrate through both Claude and Codex:

1. Analyze the technologies across all `*.atg.se` targets with bounded calls.
2. Create or explicitly update the requested `httpx-tf` Whiterabbit template.
3. Resolve the full target selection and show its count/sample.
4. Submit the job once and return its ID/status without another confirmation.
5. Inspect job progress and safe output.
6. Create/update/validate non-secret Ansible artifacts.
7. Launch, inspect, and cancel an Ansible run using an existing opaque
   credential reference.
8. Create/update a vulnerability through the closed schema and analyze
   vulnerability/program/CVE/job/run statistics.
9. Refuse secret reveal/input, record deletion, governance changes, and worker
   identity calls because no such tools exist.
10. Complete without the old eight-call failure or a fictional re-approval
    request.

## Production gate

Operator approval authorizes specification, planning, and implementation. It
does not enable production automatically. Each phase remains subject to the
Assistant production checklist. Production evidence must include exact catalog
and schema captures, route classification, provider parity, secret/deletion
negative tests, network isolation, live effect receipts, audit inspection,
rollback, and an independent enable decision.

## Self-review

- The goal grants broad operational API access rather than the previous
  read/create/edit-only interpretation.
- “All access” is measurable through route/OpenAPI classification and does not
  mean automatic exposure.
- Every effect remains dedicated, closed, scoped, revocable, validated,
  idempotent, attributed, disclosed, and audited.
- Secrets, deletion, governance, worker identity, and generic tools remain
  permanently unavailable.
- No placeholder, wildcard authority, or generic dispatcher is part of the
  approved design.
