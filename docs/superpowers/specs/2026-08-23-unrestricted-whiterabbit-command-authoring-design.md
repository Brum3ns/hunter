# Unrestricted Whiterabbit Command Authoring — Design & Threat-Model Delta

**Status:** APPROVED BY OPERATOR

**Date:** 2026-08-23

**Approval trail:** The operator explicitly stated that both the Control Center
and the Assistant must accept any command, including commands such as `bash`,
`python`, `sudo`, `docker`, and `rm`, approved the in-chat design that removes
the command allowlist entirely, and then reviewed and approved this written
delta before implementation under the repository's Assistant capability-change
rule.

## Summary

Remove the Whiterabbit executable-name allowlist from Hunter. Authenticated
Control Center users and the configured Assistant administrator may create,
edit, and validate templates containing any non-empty executable name. The
Assistant may then submit those templates through the existing dedicated
Whiterabbit job workflow when the administrator's message requests it.

This is an intentional security-boundary change. Because the Assistant already
has dedicated template authoring and job-submission capabilities, accepting any
executable makes that workflow capable of arbitrary command execution inside
the Whiterabbit execution environment. Selecting `bash`, `sh`, an interpreter,
or another general-purpose binary can produce network, filesystem, process,
privilege, data-destruction, or exfiltration effects. Hunter will disclose this
plainly and will not claim that structural validation can constrain those
semantics.

The change removes only the executable-name restriction. Exact Hunter MCP tools,
closed request schemas, non-wildcard authorization, live feature gates, budgets,
idempotency, human attribution, metadata-only audit, and production review stay
mandatory.

## Relationship to Earlier Designs

This delta supersedes the Whiterabbit command-allowlist requirements in:

- `2026-07-10-hunter-control-center-whiterabbit-api-design.md`; and
- `2026-07-30-assistant-approval-free-create-design.md`.

It amends the administrator-proxy boundary in
`2026-08-19-assistant-mcp-administrator-proxy-design.md` only for execution
reached through the existing dedicated Whiterabbit template and job tools. That
design's blanket prohibition on generic execution previously relied in part on
the template command allowlist. This delta records the operator's narrower
exception: arbitrary command content is allowed within a Whiterabbit template,
and an explicitly requested Whiterabbit job may execute it.

The following administrator-proxy requirements remain unchanged:

- Hunter MCP is the Assistant's only Hunter access path.
- There is no generic MCP `execute`, `shell`, `request`, filesystem, network, or
  database tool.
- Every MCP operation remains narrowly named and cataloged with an exact scope.
- The Assistant cannot alter tools, scopes, feature gates, budgets, validators,
  providers, authentication, users, roles, tokens, service identities, or other
  security governance.
- Hunter exposes no secret-value input or output tool and no HTTP `DELETE` or
  record-destroy tool.
- Ansible authoring and execution retain their separate policies; this delta
  does not remove the Ansible module allowlist.
- Production stays disabled until the exact candidate satisfies the Assistant
  production checklist and receives an independent enable decision.

The practical distinction is explicit: Hunter does not expose an unscoped shell
API, but the dedicated Whiterabbit workflow is now an approved path to arbitrary
worker command execution. Command effects may be as powerful as the selected
binary, arguments, worker identity, filesystem, environment, privileges, and
network permit.

## Confirmed Root Cause

Two apparently separate failures have one source:

1. `ControlCenter::TemplateValidator` optionally restricts every browser/API
   template using `CONTROL_CENTER_COMMAND_ALLOWLIST`.
2. `Assistant::DraftValidation::Whiterabbit` requires the same setting to be
   non-empty and independently rejects any command absent from it.

The deployed `.env` sets the value to `curl,httpx`. With that value, the current
code reproducibly returns
`commands[0].command "dalfox" is not allowed` from Control Center and
`assistant_command_not_allowed` from Assistant validation. Existing Control
Center records can therefore be displayed while ordinary edits or dry-run
validation fail for their commands, and the Assistant incorrectly describes
the restriction as an intentional active-scanner boundary.

The root problem is not an incomplete list. Any list will reject future or
site-specific binaries and recreate the same mismatch. The selected solution
removes executable-name policy rather than expanding it.

## Selected Behavior

### Command acceptance

`ControlCenter::TemplateValidator` accepts every command name that:

- is present and non-empty; and
- contains no NUL, carriage return, or line feed.

It does not read an environment variable, consult a built-in catalog, inspect
the worker's `PATH`, classify a tool as passive or active, or reject absolute
paths, shells, interpreters, wrappers, privilege tools, containers, or file
utilities.

The same rule applies to browser-created, API-created, Assistant-created, and
Assistant-edited templates. Examples that must validate include `nuclei`,
`dalfox`, `katana`, `feroxbuster`, `gowitness`, `dnsx`, `bash`, `python`,
`sudo`, `docker`, `rm`, `/opt/tools/custom-scanner`, and binaries introduced
after this release.

### Arguments and operators

Whiterabbit passes commands as argv without an implicit shell. Hunter continues
to bound the command count, argument count, and argument length; the Assistant's
closed envelope also retains its command-name length bound. Validation continues
to reject NUL and newlines and to accept only the existing Whiterabbit
operators. Quotes, spaces, metacharacters, and shell-like strings remain literal
argv when the executable is not a shell.

If a template explicitly selects a shell or interpreter, its arguments acquire
that program's semantics. For example, `command: bash` with `-c` intentionally
creates shell execution. Hunter does not parse, simulate, or attempt to prove
the safety of such content.

The existing Assistant secret-material detector remains in place on normalized
template input. This protects Hunter from directly accepting recognizable
secret material through the Assistant schema, but it is not a command sandbox
and does not prevent a worker command from reading or transmitting data already
reachable inside its execution environment.

### Authoring policy and activation

Assistant Whiterabbit validation no longer fails closed on a missing command
policy and no longer returns `assistant_command_policy_unconfigured` or
`assistant_command_not_allowed`.

The versioned authoring policy reports an explicit unrestricted command policy
instead of a `command_allowlist`, while continuing to publish structural bounds,
allowed operators, and supported placeholders. The command allowlist is removed
from Assistant activation requirements. An absent setting cannot disable the
Assistant or silently narrow template behavior.

`CONTROL_CENTER_COMMAND_ALLOWLIST` and its `HUNTER_` Compose input are removed
from development and production Compose, `.env.example`, the local `.env`,
runbooks, and active configuration documentation. A stale externally supplied
variable has no effect after upgrade.

## Authorization and Human Approval

The human approval model remains message-scoped. Submitting a message as the
configured Assistant administrator approves the currently enabled dedicated
Whiterabbit operations reasonably necessary to fulfill that message, including
authoring an unrestricted template and submitting a job from it. There is no
second confirmation dialog.

Authority remains split across exact tools and scopes:

- template validation uses `validate_whiterabbit_template` or
  `validate_whiterabbit_yaml`;
- template creation uses `create_whiterabbit_template`;
- template editing uses `edit_whiterabbit_template` with optimistic locking;
- target resolution uses `resolve_job_targets`; and
- execution uses `submit_whiterabbit_job` with its dedicated launch scope and
  idempotency behavior.

Possessing one tool does not grant another. The turn grant, service identity,
human ownership, exact scope, module/tool/effect feature gates, effect budgets,
launch budgets, and global kill switch are checked as they are today. Disabling
template writes prevents later Assistant authoring; disabling Whiterabbit job
submission prevents later Assistant execution, including execution of a
previously saved unrestricted template.

Browser Control Center writes continue to require the signed human session and
same-origin CSRF protection. Browser users do not receive an Assistant turn
grant because their authenticated request is itself the direct human action.

## Data Flow

No route, MCP tool, schema family, or worker callback is added.

1. The human or Assistant submits a template through an existing Control Center
   or Assistant machine endpoint.
2. Closed-schema normalization and structural validation run.
3. The ordinary template persistence service writes the record with existing
   attribution, uniqueness, and optimistic-locking behavior.
4. A separate, explicitly requested job submission resolves targets, validates
   the saved template structurally, derives its existing idempotency key, and
   enqueues it through Whiterabbit.
5. Whiterabbit workers resolve and execute the selected binaries under the
   worker's actual runtime identity and environment.
6. Existing bounded and redacted job projections expose status and permitted
   output to the Assistant.

The command and arguments remain domain content in the template and job. They
are not copied into Assistant metadata audits, action receipts, or error bodies.

## Security Consequences and Accepted Risk

The operator explicitly accepts the following consequences for the dedicated
Whiterabbit workflow:

| Risk | Consequence | Remaining control |
|---|---|---|
| Generic worker execution | A shell, interpreter, wrapper, or custom binary can perform arbitrary behavior available to the Whiterabbit worker. | Exact template/job tools and scopes, message-scoped human approval, feature gates, budgets, idempotency, and whatever runtime isolation the reviewed worker deployment actually provides. |
| Destructive runtime effects | A command may remove or overwrite files, terminate processes, alter reachable systems, or invoke destructive remote behavior. | No Hunter record-destroy API is added; effects are limited only by the worker's real identity/environment and external target authorization. |
| Network scanning and exploitation | Commands may perform active scanning, crawling, fuzzing, exploitation, callbacks, or arbitrary network requests. | Job launch remains a separately scoped, rate-bounded, revocable capability attributed to the administrator. |
| Worker secret access or exfiltration | A command can try to read environment variables, mounted files, metadata services, or reachable credential sources and transmit what it finds. | Hunter still supplies no secret through an Assistant tool; production review must minimize and inspect worker-accessible secrets, mounts, privileges, and network access. This risk cannot be eliminated while permitting arbitrary commands. |
| Prompt-injection-triggered effects | Untrusted Hunter data may attempt to persuade the model to author or submit a harmful command. | Provider policy continues to treat retrieved data as non-instructional; exact tools, scopes, live gates, and budgets limit authority. Semantic intent is not enforceable server-side, so residual risk is accepted. |
| Reduced command-level audit detail | Metadata-only Assistant audits deliberately omit template commands and arguments. | The ordinary template/job records retain domain content and attribution; audit proves who invoked which dedicated operation and its target/receipt without duplicating sensitive content. |
| Future binary exposure | A newly installed worker binary becomes usable without a Hunter deploy or policy update. | Worker package installation and runtime image governance become the effective executable boundary and must be reviewed as part of deployment. |

This delta does not describe unrestricted command execution as safe. It records
that the configured administrator deliberately prefers unrestricted
Whiterabbit capability over command-name policy and accepts the worker-level
consequences.

## UI Disclosure

The Assistant settings and chat disclosure must say, in plain language, that:

- an administrator message can cause the Assistant to create or edit a
  Whiterabbit template using any command and submit it without another prompt;
- those jobs can perform arbitrary network, filesystem, process, privilege, or
  destructive actions available to the Whiterabbit worker;
- the administrator is responsible for target authorization and the requested
  command's effects;
- template authoring and job execution remain attributable, audited at the
  metadata level, budgeted, and immediately revocable through human-controlled
  gates; and
- disabling the Assistant or Whiterabbit execution capability prevents new
  Assistant actions but does not erase saved templates or reverse completed
  external effects.

The UI must not claim a permanent no-delete or no-generic-execution guarantee
without explicitly limiting that statement to Hunter API record operations and
excluding the approved Whiterabbit runtime exception.

## Audit, Errors, and Observability

Existing metadata-only audit fields remain authoritative: human user,
conversation, turn, provider, tool, exact scope, effect class, target type/ID,
selection count, outcome, stable error, duration, byte counts, capability
version, idempotency result, and correlation ID.

Audits and action receipts continue to omit prompts, replies, command names,
arguments, template YAML, target values, job output, and secrets. Ordinary
template and job records remain the source for authorized domain inspection.

The removed command-policy errors disappear from active behavior and UI maps:

- `assistant_command_policy_unconfigured`;
- `assistant_command_not_allowed`; and
- `missing_command_allowlist`.

Structural failures continue to return existing closed validation errors.
Authorization, gate, budget, conflict, idempotency, not-found, and upstream
failures remain unchanged.

## Implementation Surface

The implementation must remain focused on removing the policy and updating its
evidence:

- Remove allowlist parsing and executable-name rejection from
  `ControlCenter::TemplateValidator`.
- Remove Assistant-specific allowlist configuration and rejection from
  `Assistant::DraftValidation::Whiterabbit`.
- Change `Assistant::AuthoringPolicy` from an allowlist claim to an explicit
  unrestricted-command declaration while retaining its structural contract.
- Remove the command allowlist from `Assistant::Config::REQUIRED_SETTINGS` and
  from the Assistant UI's activation-reason mapping.
- Remove the environment mapping and documentation from `.env.example`, the
  local `.env`, `docker-compose.yaml`, and `docker-compose.prod.yaml`.
- Update active runbooks and comments that describe command allowlisting.
- Amend `AGENTS.md` with this exact approved exception and amend the Assistant
  production checklist with candidate-specific evidence requirements.
- Update Assistant disclosure copy and its presence tests.
- Update tests that intentionally configured or asserted the retired policy.

No database migration, new route, new MCP tool, new scope, new worker callback,
or new generic Hunter dispatcher is required.

## Testing

### Regression tests

- `ControlCenter::TemplateValidator` accepts representative scanners,
  shells/interpreters, privilege/container/file utilities, absolute custom
  paths, and unknown future binary names.
- A stale `CONTROL_CENTER_COMMAND_ALLOWLIST=httpx` environment value cannot
  narrow validation.
- Structured and YAML Control Center validation/create paths accept `nuclei`,
  `dalfox`, and a general-purpose executable.
- Assistant draft validation accepts the same commands without any command
  policy environment setting.
- Assistant machine validate/create/edit paths accept unrestricted commands and
  retain closed success projections.
- The authoring policy advertises unrestricted commands and contains no
  `command_allowlist`.
- Assistant activation has no `missing_command_allowlist` reason.

### Adversarial and invariant tests

- Empty command names, NUL/newline content, invalid operators, excessive
  commands, excessive arguments, oversized arguments, unknown schema fields,
  and malformed YAML still fail with stable outcomes.
- Recognizable secret-bearing Assistant input still fails before persistence.
- Wrong service identity, user, turn, provider, tool, scope, expired grant,
  disabled live gate, exhausted effect budget, and exhausted launch budget
  still fail without mutation or enqueue.
- Duplicate creation and retry fixtures prove idempotency and uniqueness; a
  repeated job submission does not enqueue twice.
- Template edits retain optimistic-lock conflict behavior.
- Audits, action receipts, errors, and provider-visible projections do not echo
  command content or secret fixtures.
- Catalog and provider parity tests prove that no generic MCP shell, network,
  filesystem, database, request, or execution tool was added.
- Ansible command/module restrictions remain unchanged.

### Mutation check

The tests must fail if executable-name filtering is restored in either the
domain or Assistant layer, if a stale environment setting affects behavior, if
structural validation is bypassed, if secret detection is removed, if a live
gate no longer revokes, if retries duplicate effects, or if command content
enters metadata-only audit.

## Production Evidence and Rollout

Operator approval authorizes implementation; it does not enable production.
The exact candidate must add a dedicated row to
`docs/security/hunter-assistant-production-checklist.md` and record:

- Rails regression/adversarial results for unrestricted browser and Assistant
  template validation, creation, editing, and job submission;
- exact Hunter MCP/Codex/Claude catalog parity proving no generic tool was
  introduced;
- live runs through both direct providers using an active scanner command and a
  separate installed command that was never in the former allowlist;
- idempotent receipt, human attribution, metadata-only audit, and immediate
  template-write/job-submit gate revocation evidence;
- inspection of the Whiterabbit worker image, user, capabilities, mounts,
  environment-variable names, reachable networks, and installed binaries;
- canaries proving command/template/job content and worker-accessible secret
  fixtures do not leak into Assistant audits, logs, errors, or projections;
- authorized-target and rollback records; and
- an independent Reviewer decision that explicitly acknowledges arbitrary
  worker execution and the residual destruction/exfiltration risk.

The candidate remains disabled until that evidence is complete. Rollback uses
the Assistant and operational feature gates first, revokes active grants, then
restores a previously approved complete image set. Rollback does not reverse a
job's completed external effects.

## Alternatives Rejected

### Expand the existing list

Adding the currently observed scanners would fix only today's names. It would
continue rejecting custom and future tools, keep human and Assistant behavior
coupled to deployment configuration, and recreate the same production failure.

### Add an `ALLOW_ANY_COMMAND` toggle

A second deployment toggle would preserve a hidden activation/configuration
failure mode while adding no meaningful protection once enabled. Existing
human-controlled template-write, job-submit, module/effect, and global gates
already provide immediate revocation at the capability level.

### Discover installed executables dynamically

Worker discovery is still an allowlist, can differ across workers, leaks runtime
inventory into policy, and introduces race conditions between validation and
execution. The operator requested semantic acceptance of every command, not
validation against today's `PATH`.

## Explicitly Out of Scope

- A generic Hunter MCP shell, request, network, filesystem, database, or
  execution tool.
- Direct Assistant access to a Whiterabbit worker, runner callback, Docker
  socket, host filesystem, or worker identity.
- Removing closed schemas, bounds, structural validation, secret-input
  detection, authorization, gates, budgets, idempotency, attribution, audit, or
  output redaction.
- Removing the Ansible module allowlist or widening secret-bearing Ansible
  operations.
- Adding Hunter API record deletion or security/governance capabilities.
- Static interpretation of whether a command is authorized, safe,
  non-destructive, or within a bug-bounty program's rules.
- Automatic installation of a requested binary or synchronization of worker
  images.
- Reversing external effects caused by an executed job.

## Definition of Done

- No active source, deployment configuration, or documentation makes
  Whiterabbit executable acceptance depend on a command allowlist.
- Browser, public API, and Assistant validation/persistence accept arbitrary
  structurally valid executable names consistently.
- Existing dedicated Assistant tools can author and submit those templates only
  under their exact scopes, live gates, budgets, idempotency, and human
  attribution.
- UI disclosure accurately communicates arbitrary worker execution and its
  destructive/exfiltration consequences.
- `AGENTS.md` records the approved narrow exception and retains all unrelated
  capability rules.
- Regression, adversarial, full-suite, catalog-parity, and documentation checks
  pass.
- The production checklist contains the new evidence gate and production stays
  disabled pending its independent review.

## Self-Review

- **Placeholder scan:** The design contains no unresolved marker, unset
  requirement, or unspecified policy choice. Candidate evidence fields remain
  in the production checklist, not this design.
- **Internal consistency:** Every command name is accepted, while structural
  validation and Assistant secret-input detection remain. The document does not
  claim that those controls sandbox an explicitly selected shell or arbitrary
  worker binary.
- **Scope:** The exception is limited to content authored and executed through
  existing dedicated Whiterabbit tools. No generic MCP tool, route, scope, or
  worker callback is added.
- **Ambiguity:** "Any command" explicitly includes shells, interpreters,
  privilege tools, container tools, file utilities, absolute paths, custom
  binaries, active scanners, and future binaries. Runtime effects are limited
  only by the Whiterabbit worker's actual environment, not by Hunter command
  policy.
