# Assistant MCP Full-Access Reading and Permission-Free Authoring — Design & Threat-Model Delta

**Status:** APPROVED BY OPERATOR

**Date:** 2026-07-30

**Approval record:** The operator requested full non-secret Hunter reads and permission-free create/edit for all Whiterabbit templates and Ansible playbooks, selected conflict-safe create semantics, confirmed editing applies to every existing artifact, and authorized specification, planning, implementation, and verification to proceed without further questions.

## Goal

Make Hunter chat reliably complete requests such as “create a Whiterabbit script that runs httpx to prove a target” in one turn. The Assistant may read the non-secret operational data it needs across Hunter and may create or explicitly edit Whiterabbit templates and Ansible playbooks without a per-operation confirmation. It may never implicitly overwrite on create, delete an artifact, create/run a job, run a playbook, execute a command, change settings, or access credentials or secret values.

An ordinary `docker compose up --build` on the existing deployment must rebuild the relevant binaries and return the chat to a ready state without a rake task, token copy/paste, migration command, or repeated Claude login. The existing `.env` machine credentials and the persistent `assistant_claude_home` login volume remain the deployment prerequisites; `docker compose up --build` preserves both.

## Confirmed current failures

The design addresses root causes observed in source and in the live app on the Docker bridge gateway:

1. `create_whiterabbit_template` and `create_ansible_playbook` are registered in `hunter-mcp`, but the Claude wrapper's default `--allowedTools` contains only the 20 read tools.
2. The Claude wrapper's appended system prompt says all Hunter tools are read-only and forbids calls outside explicit data lookups. It therefore discourages the approved create action.
3. Rails issues write scopes, but `/api/v1/assistant/machine/grant` does not return `write_scopes`; the Go `transport.Grant` has no write scopes; and `Runner.Dispatch` compares every tool scope only against `ReadScopes`. A write call therefore fails `scope_not_granted` even when its tool and write scope are valid in Rails.
4. The Whiterabbit MCP schema makes command `args` and `operator` optional, while `Assistant::DraftEnvelope.whiterabbit` rejects them when omitted. Model output that naturally omits an empty operator receives 422.
5. The live Assistant answered the exact httpx request with “I don't have permission,” despite producing a usable draft and reading an existing template example.
6. The legacy gateway still requires the MCP server to advertise exactly the original six tools. The expanded catalog makes that profile fail connection rather than safely accepting a known subset.
7. Some read projections omit useful non-secret data. A live “programs in trash” request failed because program tools omit the turn user's favorite/trash/view state. Targets omit useful normalized probe fields, and vulnerabilities omit all evidence rather than returning a bounded redacted view.
8. The current Claude environment override accepts any future `mcp__hunter__*` name by prefix. An operator override can therefore widen the CLI allowlist beyond the reviewed catalog.
9. The settings/API disclosure does not expose the current Control Center authoring toggle even though the database column exists.

## Product semantics

### Create

- `create_whiterabbit_template` and `create_ansible_playbook` persist immediately when the user explicitly asks to create/add/save a new artifact.
- Create always uses a new model instance. It never loads or modifies an existing row.
- A duplicate name returns a stable `name_conflict`; it never becomes an update. The Assistant explains that the artifact exists and requires a later explicit edit/update request.
- Create requires no browser confirmation or MCP permission prompt.

### Edit

- New tools: `edit_whiterabbit_template` and `edit_ansible_playbook`.
- Editing is available for every existing artifact, regardless of whether a human or the Assistant created it.
- The user's current message must explicitly ask to edit/update/change an existing artifact. Reading an artifact, creating one with a duplicate name, or generating suggestions is not edit intent.
- The tool identifies the row by integer ID and requires `expected_lock_version`. The Assistant obtains both with the matching `get_*` tool.
- The input carries a closed `changes` object with at least one allowed field. Rails combines those changes with the current row, validates the complete resulting artifact, then persists through the existing service with optimistic locking.
- A stale version returns `destination_stale`; it never retries blindly. The Assistant may re-read and retry only while fulfilling the same explicit edit request.
- Edit requires no browser confirmation or MCP permission prompt.

### Never permitted

There are no Assistant tools or machine routes for deleting templates/playbooks, submitting Whiterabbit jobs, creating/canceling Ansible runs, changing credentials/variables/settings, shelling out, reading files, browsing arbitrary URLs, or making generic API requests. No create/edit tool may be widened into a generic write proxy.

## Considered approaches

### A. Repair the dedicated module tools and add two dedicated edit tools — selected

Keep named, closed, module-specific tools; repair write-scope transport; add conflict-safe edit endpoints; expand only explicit safe read projections; and make the Claude allowlist an exact reviewed set. This is the smallest approach that provides the requested smooth workflow while preserving independent revocation, validation, audit, and schema review.

### B. Give the model an ordinary Hunter API token or generic request tool — rejected

This would be superficially flexible but would expose unrelated CRUD and future routes, make secret/settings exclusion difficult to prove, violate the repository prohibition on generic network/write tools, and make delete/run escalation a configuration accident.

### C. Turn create into an upsert — rejected by operator

This is convenient for name collisions but makes “create” an implicit overwrite. The operator selected strict create plus explicit edit.

## Capability and authorization

The existing `control_center_write_enabled` setting becomes the independently revocable **Control Center authoring** switch for both create and edit. It defaults on as it does today, requires no migration, and remains independent of every read capability and of the global Assistant kill switch.

The closed write scopes become:

- `control_center_templates_write` — create Whiterabbit template
- `control_center_templates_edit` — edit Whiterabbit template
- `control_center_ansible_write` — create Ansible playbook
- `control_center_ansible_edit` — edit Ansible playbook

The tools are separately named and separately checked even though the single authoring switch revokes them together. No wildcard is accepted. `TurnGrant::WRITE_SCOPES`, immutability validation, issuer tests, introspection output, Go transport decoding, and runner scope enforcement all use this exact list.

`Assistant::Grants::Issuer` exposes explicit tool sets:

- `LEGACY_TOOLS`: the six context/policy/validation tools used only by the optional legacy gateway.
- `CHAT_READ_TOOLS`: the 20 reviewed domain read tools.
- `CHAT_CREATE_TOOLS`: the two create tools.
- `CHAT_EDIT_TOOLS`: the two edit tools.
- `CHAT_TOOLS`: read plus enabled create/edit tools.

Claude turns receive `CHAT_TOOLS`; legacy turns receive `LEGACY_TOOLS`. A disabled authoring switch strips all four authoring tools and all four write scopes at grant issue time. The machine endpoints also recheck the live switch so it can revoke already-issued grants.

`/machine/grant` returns `write_scopes` as a required closed field. The Go runner checks a tool's required scope against the union of the grant's closed read/write scopes. Because read and write slug sets are disjoint and Rails validates both, a write slug cannot be smuggled through `read_scopes`.

## Machine write contracts

### Whiterabbit create

`POST /api/v1/assistant/machine/control_center/templates`

Input remains `{template:{...}}` and supports the full authoring fields: required `name`, `kind`, and non-empty `commands`; optional `description`, `tags`, `output`, and closed `target`. Each command requires only `command`; missing `args` normalizes to `[]` and missing `operator` normalizes to `""` consistently in Go and Rails.

### Whiterabbit edit

`PATCH /api/v1/assistant/machine/control_center/templates/:id`

Input:

```json
{
  "expected_lock_version": 3,
  "changes": {
    "description": "Probe targets with httpx",
    "commands": [{"command":"httpx","args":["-l","__TARGET_FILE__"],"operator":""}]
  }
}
```

Allowed changes are `name`, `kind`, `description`, `tags`, `output`, `commands`, and `target`. Unknown keys, empty changes, out-of-range values, and unsafe strings fail before persistence.

### Ansible create

`POST /api/v1/assistant/machine/control_center/ansible/playbooks`

Input remains `{playbook:{...}}` with required `name` and `source`, plus optional bounded `description` and `variable_set_ids`. It cannot inline inventory, credentials, secret variables, roles, collections, or execution configuration.

### Ansible edit

`PATCH /api/v1/assistant/machine/control_center/ansible/playbooks/:id`

Input requires `expected_lock_version` and a non-empty closed `changes` object whose keys are `name`, `description`, `source`, and `variable_set_ids`.

### Shared write pipeline

Every create/edit action executes this order:

1. authenticate service identity and turn grant;
2. authorize the exact tool and exact create/edit scope;
3. recheck global Assistant and Control Center authoring switches;
4. consume the bounded authoring rate limit;
5. closed-decode and normalize input;
6. for edits, load by ID and check the expected lock version;
7. construct the complete candidate state;
8. run `Assistant::DraftValidation::Whiterabbit` or `Assistant::DraftValidation::AnsibleStatic` fail-closed;
9. persist with the existing `ControlCenter::*::Persist` service and the human turn user;
10. record metadata-only success/failure audit; and
11. return only `{correlation_id, <artifact>:{id,name,lock_version}}`.

The strict assistant validators and model validators remain mandatory. Edit never validates only the patch; it validates the merged final artifact. Duplicate names, stale versions, rate limits, disabled authoring, invalid content, and missing records have stable non-secret error codes. No request content or artifact content enters audit metadata.

## Read access: broad but secret-free

The Assistant may query all current domain modules already represented by the 20 read tools: targets, CVEs, vulnerabilities, sitemap endpoints, programs, Whiterabbit templates/jobs, and Ansible playbooks/run groups/runs/events. It receives all bounded fields useful for analysis and authoring, not settings, credentials, raw secret variables, encrypted execution payloads, or arbitrary model serialization.

Existing tool names and dedicated read scopes remain unchanged. Changes are projection/filter parity, not a generic data tool.

### Targets

Full target detail adds normalized `input`, `ip`, `path`, HTTP method, content metrics, response time, producing tool, failed flag, CSP domains/FQDNs, perceptual hash, and a bounded list of safe response headers. `scan_id`, cookies, authorization headers, set-cookie values, and unrecognized headers are excluded.

### CVEs

The current full projection already contains the useful normalized CVE record and remains. Lists retain typed filters and plain substring `q`; descriptions must state this clearly.

### Vulnerabilities

Full detail adds target input/method and a bounded `evidence` object containing sanitized request, response, curl, and extracted evidence. The sanitizer removes sensitive header values, bearer/basic credentials, cookie/set-cookie values, private keys, cloud keys, URL userinfo, credential assignments, and control characters. If a field cannot be made safe, it is omitted and its `*_redacted` flag is true. `llm_reasoning`, operator identity fields, and scan IDs remain excluded.

### Sitemap

The existing normalized endpoint detail remains; its complete filter/dork grammar stays advertised.

### Programs

Programs add the non-secret catalog detail used by the web department: date/status, description, organization, reward grid, hall-of-fame/hacktivity flags, policy/rules text, qualifying and non-qualifying vulnerabilities, account-access instructions, required user agent, restricted/VPN metadata, and complete bounded scope entries. The projection also adds turn-user state: `favorited`, `trashed`, and `last_viewed_at`.

`list_programs` adds the web department's missing filters (`favorites_only`, `trash_only`, response/bounty/report windows) and passes the human turn user's favorite/trash sets into `Programs::Query`. This lets the Assistant answer “what is in trash?” without creating a new state-changing capability.

### Control Center

- Templates add `lock_version` and non-secret attribution; commands/targets remain available after secret checking.
- Jobs add non-secret selection/target summary and attribution needed to explain prior work, while excluding idempotency keys and any value that fails secret filtering.
- Playbooks add `lock_version`, description, source, variable-set IDs, and attribution; secret variable values and credentials remain excluded.
- Run groups/runs/events keep encrypted payloads, lease material, raw inventories, known-hosts data, runner identity, and credentials excluded. Existing redacted stdout/event data remains available.

### Defense in depth

Rails owns an explicit projection for every module and applies a final bounded secret-safety check before render. The Go broker retains its independent size/secret checker and exact-key output validation. Expanded nested objects receive explicit validators rather than being accepted only because their top-level key is known.

## Claude and MCP behavior

The default Claude tool list becomes the exact 24-tool chat catalog: 20 reads, two creates, and two edits. `ASSISTANT_CLAUDE_MCP_TOOLS` may only restrict that set; unknown or future `mcp__hunter__*` names are dropped. Built-in Claude tools (`Bash`, `Read`, `Write`, `Edit`, `WebFetch`, etc.) remain unavailable.

The appended system policy says:

- use read tools when the user requests Hunter data or when a read is necessary to fulfill an explicit Hunter create/edit request;
- call create/edit directly without asking for permission when the user explicitly requests the action;
- never convert a create collision into an edit;
- never edit without explicit current-message edit intent;
- never delete, run, send, schedule, shell, browse, or change settings;
- prefer the fewest well-filtered calls and report stable errors plainly.

MCP server instructions and each write-tool description repeat the no-overwrite/explicit-edit rules. The optional legacy gateway accepts an advertised superset but exposes and calls only its fixed six tools; unexpected/missing required tools still fail closed.

## UI and administration

The Assistant panel and Settings disclosure state that the Assistant can read non-secret Hunter operational data and can create or explicitly edit validated templates/playbooks without per-operation confirmation; it cannot delete or run them.

`serialize_setting` includes `control_center_write_enabled`. The Settings form exposes the independently revocable Control Center authoring checkbox. The update controller persists it through the audited `enable_control_center_write!` / `disable_control_center_write!` methods rather than a raw attribute update.

## Rebuild and readiness

No database migration is required. The existing JSONB write scopes and artifact lock-version columns are sufficient.

The encoded machine-request and per-result ceilings are 512 KiB (2 MiB total
per grant). These ceilings include JSON envelopes and escaping, so the closed
65,536-byte Ansible source maximum is reachable for create, edit, and readback
without weakening the source validator. Aggregate read responses remain
fail-closed at the per-result ceiling.

Development Compose already rebuilds `web`, `hunter-mcp`, and `assistant-claude`, seeds the MCP service identity from `ASSISTANT_MCP_HUNTER_TOKEN`, and mounts Claude's authenticated home as the named `assistant_claude_home` volume. The implementation must preserve those properties and update stale comments/runbooks that still describe the catalog as read-only or require repeated setup.

Acceptance for the existing deployment is exactly:

```sh
docker compose up --build
```

After services settle, a new Claude chat can read data and create/edit without any other command. Destroying the named Claude home volume or deploying to a brand-new host still requires supplying an external Claude credential once; software cannot manufacture that external account authority. A normal rebuild does not.

## Error handling

Stable public tool outcomes include:

- `name_conflict`
- `destination_stale`
- `artifact_not_found`
- `validation_failed` with bounded stable codes
- `control_center_write_disabled`
- `authoring_rate_limited`
- `scope_not_granted`
- `turn_grant_rejected`
- `tool_response_rejected`

No controller returns validation internals, stack traces, secret-shaped values, or database exceptions. Reservations are released on every non-success. Once a write commits, response-byte accounting may revoke further use but never turns the committed write into a false 403.

## Audit

Every successful create/edit records `machine.create` or `machine.edit` with correlation ID, human user ID, turn/conversation/profile IDs, artifact type/ID, operation, outcome, and byte counts only. Rejections that reach a machine write controller record operation, outcome, and stable reason only. Names, commands, YAML, diffs, prompts, and result bodies are never audited.

## Adversarial and acceptance tests

### Rails

- grant introspection returns exact immutable read and write scopes;
- create/edit are denied without their exact tool and scope;
- switch-off strips authoring tools/scopes from new grants and denies old grants;
- create duplicate never updates;
- edit requires explicit tool, ID, expected version, and at least one closed change;
- stale edit changes nothing;
- forbidden Whiterabbit command and forbidden Ansible module change nothing;
- editing only a description still revalidates the existing full artifact;
- unknown fields, overlong values, secret content, and malformed target/command structures fail closed;
- successful writes are attributed to the turn user and metadata-only audited;
- safe program personal state works only for the turn user;
- secret headers/evidence/credentials/settings never appear in projections;
- reservations and rate-limit paths are released/accounted correctly;
- OpenAPI and UI disclosures match behavior.

### Go MCP

- transport closed-decodes `write_scopes` and rejects missing/unknown grant fields;
- runner accepts create/edit only from matching write scopes and rejects them from read scopes;
- create/edit input and output schemas are closed and bounded;
- Whiterabbit missing args/operator normalizes consistently;
- edit routes use PATCH and path-escape only integer IDs;
- output validators require exact `{id,name,lock_version}`;
- catalog golden contains all 24 chat tools and no delete/run/generic tool;
- the Claude default allowlist equals those 24 names;
- environment overrides can narrow but cannot widen the allowlist;
- appended policy includes permission-free create, explicit-only edit, no create overwrite, and no delete/run;
- built-in Claude tools remain unavailable;
- legacy gateway accepts a catalog superset but still calls only its six fixed tools.

### Live acceptance after rebuild

1. `docker compose up --build` only.
2. “How many targets run nginx?” returns a real filtered count.
3. “What programs are in trash?” returns the current user's trashed programs.
4. “Create a Whiterabbit script that runs httpx against a target file” creates a visible Control Center template in the same turn without confirmation.
5. Repeating the same create returns a conflict and does not alter the row.
6. “Edit that template to add `-tech-detect`” updates it without confirmation using the current lock version.
7. A stale concurrent edit is rejected without overwriting.
8. Equivalent create/edit acceptance passes for an Ansible playbook.
9. Requests to delete or run are refused because no such tool exists.

## Threat-model delta and approved exception

This document supersedes the create-only limitation in `2026-07-30-assistant-approval-free-create-design.md` for the reviewed candidate. The operator explicitly approves waiving per-operation human confirmation for **create and explicit edit** of Whiterabbit templates and Ansible playbooks, including artifacts created by humans, under all controls in this document.

The approval does not cover delete, run, send, schedule, credential/variable mutation, settings changes, new artifact types, generic tools, wildcard scopes, validator bypass, secret disclosure, or implicit create-to-edit conversion. Any such change requires another approved delta.

Production activation remains gated by the production checklist and independent review evidence. This operator approval authorizes implementation; it does not by itself mark the production checklist complete.

## Self-review

- No placeholders or TBDs remain.
- Create and edit semantics do not conflict: create never overwrites; edit requires explicit intent and optimistic locking.
- The write authorization chain is represented at Rails grant issuance, introspection, Go transport, Go runner, MCP tool, machine endpoint, live toggle, and persistence.
- Every new effectful action has a dedicated closed tool/schema, dedicated non-wildcard scope, independent revocation from reads, UI disclosure, metadata-only audit, stable errors, and adversarial tests.
- Generic API/network/filesystem/shell/delete/run tools remain prohibited.
- Normal rebuild readiness is explicit and does not claim that a new external Claude account can be authenticated without a credential.
