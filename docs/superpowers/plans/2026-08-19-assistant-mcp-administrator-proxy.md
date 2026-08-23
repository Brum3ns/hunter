# Hunter Assistant MCP Administrator Proxy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:executing-plans` to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the configured Hunter administrator broad, approval-free access
to Hunter's non-secret, non-delete operational API through exact MCP tools,
including bulk analysis, vulnerability authoring, Whiterabbit job submission,
and Ansible authoring/execution, while keeping Hunter secrets and governance
outside the model boundary.

**Architecture:** A reviewed versioned capability catalog is the shared source
of truth for tool names, exact non-wildcard scopes, feature gates, schemas,
budgets, audit events, and route classifications. Claude and Codex receive only
the catalog's enabled MCP tools. Go keeps an explicit module implementation for
each tool, and Rails keeps exact Assistant machine routes that re-authorize the
turn's human administrator and call existing domain services. Effects return
idempotent action receipts. No generic Hunter API proxy is introduced.

**Tech Stack:** Ruby 3.3.6, Rails 8, PostgreSQL/MongoDB, Go 1.25, MCP Go SDK,
Claude Code CLI, Codex CLI, Minitest, Go testing, OpenAPI YAML.

## Global constraints

- Implement the approved delta in
  `docs/superpowers/specs/2026-08-19-assistant-mcp-administrator-proxy-design.md`.
- Every Hunter read or effect initiated by the model goes through the
  authenticated `hunter` MCP server and a short-lived turn grant.
- Never expose secret input/output, destructive delete, Assistant/security
  governance, user/role/token/provider administration, or runner/executor
  machine callbacks.
- Never add generic HTTP, network, shell, filesystem, database, credential,
  send, schedule, or execute tools. Dedicated job and Ansible actions are the
  only approved execution boundary.
- Use exact tool names, exact non-wildcard scopes, closed input/output schemas,
  live feature-gate checks, metadata-only audit, and human attribution.
- Use the existing persistence/validation/domain services. MCP controllers must
  not duplicate browser-controller `permit!` behavior or bypass validators.
- Effects require idempotency keys; edits require IDs and current
  `expected_lock_version`; launches and submissions never duplicate on retry.
- Default limits are 64 calls per turn (hard ceiling 128), 1 MiB per call and
  16 MiB per turn, 30-minute maximum grant lifetime, 32 effects per turn and
  120 per hour, and 16 launches per turn and 60 per hour. Keep the approved hard
  ceilings in the design as validation limits.
- Preserve unrelated worktree edits. Do not commit unless the operator asks.

## Catalog and file structure

- Create `web/config/assistant_capabilities.yml`: versioned reviewed catalog
  with every exact enabled tool and every `/api/v1` classification.
- Create `web/app/services/assistant/capability_catalog.rb`: fail-closed loader,
  schema validation, enabled/gate filtering, scope maps, and API coverage data.
- Create `web/lib/tasks/assistant_capabilities.rake`: CI task comparing Rails
  routes, OpenAPI methods, and catalog classifications.
- Modify grants, settings, budgets, and action receipts in `web/app/services`
  and `web/app/controllers/api/v1/assistant/machine`.
- Add module-specific Rails machine controllers/projections for new reads,
  analyses, writes, utilities, and actions.
- Extend `assistant/mcp/internal/tool`, `runner`, `transport`, and dedicated
  module packages; never implement a generic request dispatcher.
- Generate/check exact Claude and Codex allowlists from the reviewed catalog
  artifact and update the MCP server instruction text.
- Update Assistant settings disclosure, OpenAPI, the production checklist, and
  live-smoke documentation.

---

### Task 1: Add the reviewed capability catalog and fail-closed API coverage

**Files:**

- Create: `web/config/assistant_capabilities.yml`
- Create: `web/app/services/assistant/capability_catalog.rb`
- Create: `web/lib/tasks/assistant_capabilities.rake`
- Create: `web/test/services/assistant/capability_catalog_test.rb`
- Create: `web/test/tasks/assistant_capabilities_test.rb`
- Modify: `web/config/routes.rb`
- Inspect as inputs: `web/config/openapi/*.yaml`

**Interfaces:**

- Produces: `Assistant::CapabilityCatalog.load`, `.tools`, `.tool!(name)`,
  `.enabled_tools(settings:)`, `.scopes`, and `.api_classifications`.
- Produces: `bin/rails assistant:capabilities:verify`.
- Each tool entry declares name/module/operation/effect/scope/schema versions,
  machine method/path, API operation, gate, rate profile, byte profile,
  idempotency/locking, secret policy, audit event, safe target metadata, and
  rollout state.
- Each current API operation receives exactly one approved classification.

- [x] Write catalog-loader tests for duplicate names, wildcard scopes, missing
  required keys, unsafe effect/secret combinations, machine callback exposure,
  and an enabled tool without a dedicated machine route.
- [x] Write coverage-task tests proving an unclassified Rails/OpenAPI operation,
  double classification, alias without a target, and enabled operation without
  a tool all fail with stable diagnostics.
- [x] Run the new focused tests and confirm they fail because the loader/task do
  not exist.
- [x] Add the complete catalog and all 139 audited API classifications from the
  approved design. Represent PATCH/PUT aliases explicitly and keep Assistant,
  runner, and executor routes classified but unavailable.
- [x] Implement strict YAML loading with deep string-key validation and frozen
  values. Reject YAML aliases, unknown catalog keys, unknown classifications,
  wildcards, secret-bearing enabled tools, DELETE machine methods, and generic
  names such as `request`, `execute`, or `run_command`.
- [x] Implement route/OpenAPI comparison without dynamically registering tools.
  Wire the task into the existing test/CI entrypoint.
- [x] Run focused catalog tests and `assistant:capabilities:verify`; expect pass.

---

### Task 2: Expand grants, live gates, budgets, rate limits, and receipts

**Files:**

- Modify: `web/app/models/assistant/turn_grant.rb`
- Modify: `web/app/models/assistant/setting.rb`
- Modify: `web/app/models/assistant/provider_profile.rb`
- Modify: `web/app/services/assistant/config.rb`
- Modify: `web/app/services/assistant/grants/issuer.rb`
- Modify: `web/app/services/assistant/grants/authorizer.rb`
- Modify: `web/app/services/assistant/rate_limiter.rb`
- Create: `web/app/services/assistant/capability_policy.rb`
- Create: `web/app/services/assistant/action_receipt.rb`
- Modify: `web/app/controllers/api/v1/assistant/machine/base_controller.rb`
- Create: `web/db/migrate/20260819010000_expand_assistant_operational_limits.rb`
- Create: `web/db/migrate/20260819010100_add_assistant_capability_settings.rb`
- Modify tests under: `web/test/models/assistant/`,
  `web/test/services/assistant/`, and
  `web/test/integration/api/v1/assistant/machine/authorization_test.rb`

**Interfaces:**

- Produces catalog-derived exact tool/scope grants; stored grant snapshots never
  widen after issue and live gates can revoke them immediately.
- Produces stable authorization errors:
  `capability_disabled`, `scope_not_granted`, `turn_grant_expired`,
  `turn_call_budget_exhausted`, `effect_rate_limited`, and
  `tool_response_rejected`.
- Produces receipt keys `receipt_id`, `tool`, `status`, safe target metadata,
  human user ID, turn ID, idempotency key, timestamps, and optional artifact
  reference; never prompt/content/result bodies.

- [x] Add failing model/migration tests for default 64 and maximum 128 calls,
  30-minute grant ceiling, byte limits, exact scopes, and setting defaults.
- [x] Add failing issuer/authorizer tests for catalog parity, no wildcard,
  profile narrowing, exact gate/effect/module disables, live revocation, stale
  grant expiry, and deterministic call/byte exhaustion.
- [x] Add failing rate-limit/receipt tests for create-update and launch profiles,
  idempotent replay, human attribution, and metadata-only audit payloads.
- [x] Apply migrations and implement the limits and settings with database
  constraints; preserve existing authoring setting behavior during migration.
- [x] Replace hand-maintained issuer arrays with validated catalog selection,
  while retaining explicit legacy-provider narrowing where still supported.
- [x] Implement `CapabilityPolicy` and require every machine action to recheck
  exact tool, scope, module/effect/tool gate, and rollout state.
- [x] Implement action receipts and stable error mapping. Ensure a committed
  effect is returned as success/idempotent replay, never a post-commit 403.
- [x] Run focused Rails tests and schema/catalog checks; expect pass.

---

### Task 3: Extend the Go MCP contract, budgets, errors, and capability tool

**Files:**

- Modify: `assistant/mcp/internal/tool/tool.go`
- Modify: `assistant/mcp/internal/runner/registry.go`
- Modify: `assistant/mcp/internal/runner/register.go`
- Modify: `assistant/mcp/internal/runner/runner.go`
- Modify: `assistant/mcp/internal/limits/budget.go`
- Modify: `assistant/mcp/internal/transport/transport.go`
- Create: `assistant/mcp/internal/catalog/catalog.go`
- Create: `assistant/mcp/internal/catalog/catalog_test.go`
- Create: `assistant/mcp/internal/modules/capabilities/module.go`
- Create: `assistant/mcp/internal/modules/capabilities/module_test.go`
- Modify: `assistant/mcp/cmd/hunter-mcp/main.go`
- Modify tests under: `assistant/mcp/internal/{tool,runner,limits,transport}`

**Interfaces:**

- Extends `tool.Tool` with catalog metadata needed for exact scope, effect,
  gate/rate/byte profile, idempotency, schema versions, and machine route parity.
- `list_hunter_capabilities` returns only safe enabled capability metadata and
  effective limits; it cannot mutate tools, scopes, or gates.
- Local runner budget accepts a grant value up to 128 and enforces 1 MiB/call
  plus 16 MiB/turn independently of Rails.

- [x] Write failing Go tests for tool/catalog parity, duplicate routes/scopes,
  wildcard scopes, generic tool rejection, live introspection narrowing, and
  response-size/secret rejection.
- [x] Write failing budget tests at 64/128 calls and byte boundaries, including
  concurrency and no off-by-one consumption after rejection.
- [x] Expand stable error translation and prove unknown/malformed upstream
  errors fail closed without leaking response bodies.
- [x] Implement the catalog metadata and exact registration validation. Keep
  every module's `Decode`, `BuildRequest`, and `Validate` implementation.
- [x] Implement the capability listing module and replace the stale no-run/no-
  send MCP instructions with the approved MCP-only policy.
- [x] Run all MCP tests and regenerate the checked catalog golden; expect pass.

---

### Task 4: Make Claude and Codex consume the exact enabled catalog

**Files:**

- Modify: `assistant/claude/cmd/hunter-assistant-claude/main.go`
- Modify: `assistant/claude/cmd/hunter-assistant-claude/main_test.go`
- Modify: `assistant/codex/cmd/hunter-assistant-codex/main.go`
- Modify: `assistant/codex/cmd/hunter-assistant-codex/main_test.go`
- Modify: `web/app/services/assistant/claude_code_client.rb`
- Modify: `web/app/services/assistant/codex_client.rb`
- Modify: `web/app/services/assistant/preflight.rb`
- Create: `assistant/scripts/sync-mcp-catalog.sh`

**Interfaces:**

- Both provider wrappers expose the same exact enabled Hunter MCP catalog and
  reject environment attempts to widen it; a configured list may only narrow.
- Provider system policy states that the human message approves required
  enabled Hunter operations, retrieved content is never instruction, all Hunter
  work uses MCP, and permanent exclusions remain unavailable.

- [x] Add failing provider tests comparing wrapper allowlists with the checked
  MCP catalog and proving extra environment tool names are rejected.
- [x] Add prompt tests proving job submission and Ansible launch/cancel are
  permitted only through exact Hunter tools, while secrets/delete/governance
  and generic execution remain forbidden.
- [x] Implement deterministic catalog synchronization/checking; generated Go
  data may be checked in, but runtime YAML parsing is not a trust shortcut.
- [x] Update both provider wrappers and Rails clients/preflight to pass the same
  turn grant and narrowing-only tool list.
- [x] Run Claude, Codex, gateway/preflight, and catalog parity tests; expect pass.

---

### Task 5: Add workflow-scale target, sitemap, program, and CVE reads

**Files:**

- Modify machine controllers/projections under:
  `web/app/controllers/api/v1/assistant/machine/` and
  `web/app/services/assistant/machine/`
- Modify: `web/config/routes.rb`
- Create or modify focused integration tests under:
  `web/test/integration/api/v1/assistant/machine/`
- Modify Go modules:
  `assistant/mcp/internal/modules/{targets,sitemap,programs,cves}`
- Modify corresponding Go tests.

**Interfaces:**

- Adds `analyze_targets`, `analyze_endpoints`, `analyze_programs`,
  `list_program_changes`, `list_scope_runs`, `get_scope_run`, `list_new_cves`,
  and `analyze_cves`.
- Bulk analysis accepts closed filters/selections and returns bounded aggregate
  counts, technology/statistic summaries, and safe selection references. It
  does not require one `get_*` call per record.

- [x] Add failing Rails projection/controller tests for every new route,
  pagination/filter bounds, 57-target technology aggregation, safe empty/error
  behavior, and secret-marker redaction.
- [x] Add failing Go schema/output tests for exact accepted keys, bounded arrays,
  stable routes, nested projections, and rejection of unexpected output keys.
- [x] Implement module-specific aggregate/query services using existing domain
  sources and explicit safe projections; never serialize raw Mongo documents.
- [x] Implement and register the dedicated Go tools.
- [x] Run all four Rails machine suites and Go module suites; expect pass.

---

### Task 6: Add closed vulnerability analysis, create, and update

**Files:**

- Create: `web/app/services/assistant/machine/vulnerability_input.rb`
- Modify: `web/app/controllers/api/v1/assistant/machine/vulnerabilities_controller.rb`
- Modify: `web/app/services/assistant/machine/vulnerability_projection.rb`
- Modify: `web/config/routes.rb`
- Modify/create tests under:
  `web/test/services/assistant/machine/` and
  `web/test/integration/api/v1/assistant/machine/vulnerabilities_test.rb`
- Modify: `assistant/mcp/internal/modules/vulnerabilities/module.go`
- Modify: `assistant/mcp/internal/modules/vulnerabilities/module_test.go`

**Interfaces:**

- Adds `analyze_vulnerabilities`, `create_vulnerability`, and
  `update_vulnerability` with a dedicated closed document schema.
- Create cannot overwrite; update requires `id`, `expected_lock_version`, and
  closed `changes`; delete is absent.

- [x] Write failing input tests for allowed scalar/enumerated/list fields,
  unknown/secret-like keys, nested evidence bounds, immutable IDs, and input
  immutability. Explicitly prove public-controller `permit!` keys do not pass.
- [x] Write failing integration tests for create/update happy paths, duplicate,
  stale, missing, validation, idempotent retry, scope/gate/rate rejection, and
  metadata-only audit with no persistence on failure.
- [x] Implement the normalizer/controller through the existing vulnerability
  model/source and explicit projection. Add optimistic locking if the domain
  record lacks it, with a migration/data normalization only if required.
- [x] Add exact Go schemas/output validation and register all three tools.
- [x] Run vulnerability service/model/controller/MCP tests; expect pass.

---

### Task 7: Complete Whiterabbit template analysis/validation and job operation

**Files:**

- Modify: `web/app/controllers/api/v1/assistant/machine/control_center/templates_controller.rb`
- Modify: `web/app/controllers/api/v1/assistant/machine/validations_controller.rb`
- Modify: `web/app/controllers/api/v1/assistant/machine/control_center/jobs_controller.rb`
- Modify: `web/app/services/assistant/machine/control_center/{template_projection,job_projection}.rb`
- Create: `web/app/services/assistant/machine/control_center/job_input.rb`
- Modify: `web/config/routes.rb`
- Modify/create matching Rails integration/service tests.
- Modify Go modules:
  `assistant/mcp/internal/modules/{cc_templates,cc_jobs,ccwrite,validation}`
- Modify corresponding Go tests.

**Interfaces:**

- Adds `analyze_templates`, `validate_whiterabbit_template`,
  `validate_whiterabbit_yaml`, `analyze_jobs`, `resolve_job_targets`,
  `submit_whiterabbit_job`, `get_control_center_health`, and
  `get_control_center_stats` while retaining safe create/edit.
- Submission uses the existing resolver, template validator, selection
  validator, persistence/enqueue service, and required idempotency key.

- [x] Write failing Rails tests for all new reads/validation endpoints, target
  resolution by explicit IDs and filters, submission validation, duplicate
  replay, queue failure, output redaction, stats bounds, gates/scopes/rates, and
  one metadata-only receipt per committed job.
- [x] Write failing Go contract tests, including the screenshot scenario:
  resolve all `*.atg.se` targets, then submit `httpx-tf` without exhausting a
  grant or requiring a second approval.
- [x] Implement closed job input and dedicated machine actions by factoring and
  calling existing `Api::V1::ControlCenter::JobsController` domain behavior;
  do not call the public controller or runner callback.
- [x] Implement health/stats safe projections and bounded job analysis.
- [x] Register exact Go tools and update output validation/stable errors.
- [x] Run template/job/validation Rails and Go suites; expect pass.

---

### Task 8: Add safe Ansible metadata, playbook, inventory, and variable tools

**Files:**

- Add/modify machine controllers under:
  `web/app/controllers/api/v1/assistant/machine/control_center/ansible/`
- Add services/projections/closed inputs under:
  `web/app/services/assistant/machine/control_center/ansible/`
- Modify: `web/config/routes.rb`
- Add matching Rails integration/service tests.
- Add/modify dedicated Go modules under:
  `assistant/mcp/internal/modules/cc_ansible_*`
- Modify: `assistant/mcp/internal/modules/cc_playbooks`
- Add matching Go tests.

**Interfaces:**

- Credential tools return safe metadata and opaque IDs only.
- Playbook tools add analysis, validation, and short-lived user-owned export.
- Inventory tools support safe create/edit/validate plus syntax, host-key, and
  connectivity utility queues/results.
- Variable tools support set create/edit and explicitly non-secret variable
  create/edit only. Secret variables and all delete operations are absent.

- [x] Add failing credential tests that seed password/private-key material and
  prove it never appears in list/get output, errors, audit, or logs.
- [x] Add failing playbook export tests for bounded selection, ownership,
  expiry, browser-only artifact reference, no archive bytes, and no filesystem
  path in the model response.
- [x] Add failing inventory input/utility tests for opaque credential IDs,
  validators, lock conflicts, idempotent task queueing, safe poll projections,
  and rejection of private keys/passwords/raw host material.
- [x] Add failing variable tests proving `secret: true`, secret types/keys, and
  updates to existing secret variables are always rejected; non-secret typed
  values remain bounded and projected safely.
- [x] Implement exact Rails services/actions using existing Control Center
  validators/persistence/task services and metadata-only receipts/audit.
- [x] Implement exact Go modules and closed schemas/output validators.
- [x] Run all Ansible artifact/utility Rails and Go suites; expect pass.

---

### Task 9: Add dedicated Ansible launch, cancel, inspection, and health tools

**Files:**

- Modify machine controllers:
  `web/app/controllers/api/v1/assistant/machine/control_center/ansible/{run_groups,runs,run_events}_controller.rb`
- Create: `web/app/controllers/api/v1/assistant/machine/control_center/ansible/executor_health_controller.rb`
- Add closed launch/cancel inputs and projections under:
  `web/app/services/assistant/machine/control_center/ansible/`
- Modify: `web/config/routes.rb`
- Add matching Rails integration/service tests.
- Modify Go modules:
  `assistant/mcp/internal/modules/{cc_run_groups,cc_runs,cc_run_events}`
- Create: `assistant/mcp/internal/modules/cc_ansible_health/module.go`
- Add/modify matching Go tests.

**Interfaces:**

- Adds `analyze_ansible_runs`, `launch_ansible_run_group`,
  `cancel_ansible_run_group`, `cancel_ansible_run`, and
  `get_ansible_executor_health`; retains safe list/get/events reads.
- Launch references existing playbook/inventory/variable-set/credential IDs,
  validates ownership and readiness, and requires idempotency. Cancel is a
  reversible state transition, not record deletion.

- [x] Write failing launch tests for valid dependencies, missing/foreign IDs,
  invalid playbook/inventory, secret projection, duplicate replay, launch rate
  limits, disabled capability, and queue failure atomicity.
- [x] Write failing cancel tests for queued/running/terminal state matrices,
  idempotent repeat, optimistic state conflict, exact scope, and audit receipt.
- [x] Write failing event/analysis/health tests proving executor tokens,
  callback payloads, environment, and raw output secrets are redacted.
- [x] Implement through existing run-group launch/cancel domain services. Do not
  expose or invoke `/ansible_executor/*` callback endpoints as MCP tools.
- [x] Add exact Go schemas/tools/output validation and stable error mapping.
- [x] Run all run-group/run/event/health Rails and Go suites; expect pass.

---

### Task 10: Expose human-only capability controls and action disclosure

**Files:**

- Modify: `web/app/controllers/api/v1/assistant/settings_controller.rb`
- Modify Assistant settings views/controllers and Stimulus code under:
  `web/app/views/assistant/` and `web/app/javascript/controllers/`
- Modify: `web/app/services/assistant/event_ingestor.rb`
- Modify: `web/app/services/assistant/audit.rb`
- Modify/create settings, UI, and JavaScript tests.

**Interfaces:**

- Human administrator can disable an exact tool, effect class, or module through
  same-origin CSRF-protected settings. The model has no settings tool.
- Conversation output renders bounded action receipts for effects without
  exposing hidden tool arguments, secret data, or raw provider output.

- [x] Add failing controller/model tests for exact closed setting bodies,
  admin-only ownership, invalid tool/effect/module rejection, CSRF, and
  metadata-only audit.
- [x] Add failing UI tests for enabled-capability disclosure, permanent
  exclusions, effective limits, action receipts, and immediate revocation text.
- [x] Implement controls backed by the validated catalog; do not accept unknown
  names or wildcard selectors.
- [x] Implement safe receipt ingestion/rendering and preserve existing chat
  streaming behavior.
- [x] Run settings, conversation, event, view/system, and JavaScript tests.

---

### Task 11: Update contracts, release gates, and adversarial coverage

**Files:**

- Modify: `web/config/openapi/assistant.yaml`
- Modify other `web/config/openapi/*.yaml` only where machine contract links or
  classifications require it.
- Modify: `docs/security/hunter-assistant-production-checklist.md`
- Modify the existing Assistant live-smoke/runbook documents.
- Modify: `assistant/mcp/internal/runner/testdata/catalog_golden.json`
- Add cross-provider/adversarial tests in Rails and Go.

**Interfaces:**

- OpenAPI documents exact schemas, scopes, stable errors, limits, idempotency,
  locking, receipts, and no-secret/no-delete boundary.
- Production remains disabled until every checklist evidence item is recorded.

- [x] Add a cross-provider parity test proving Rails, MCP, Claude, and Codex
  expose exactly the same enabled tool names/scopes and no excluded route.
- [x] Add adversarial tests for prompt injection in every retrieved record type,
  forged grants, wrong users/turns/providers/resources, stale grants, gate-off
  mid-turn, scope swapping, wildcard attempts, secret-shaped input/output,
  oversized payloads, malformed JSON, retries, concurrent rate limits, and all
  permanent exclusions.
- [x] Update OpenAPI and operational docs, then run the API classification task
  and regenerate the catalog golden deterministically.
- [x] Run full Rails and Go suites plus formatting/static checks. Record any
  environment-only verification limitation without claiming it passed.

---

### Task 12: Perform live smoke verification without widening authority

**Files:**

- No product-code changes unless a reproduced defect requires a new TDD loop.
- Record evidence only in the production checklist/runbook locations approved
  for deployment evidence.

- [x] Verify the local source-built Rails/MCP/provider tests first. Do not use
  the existing deployment as evidence for code it has not rebuilt.
- [ ] If `dockergateway:5000` is reachable and the updated application has been
  deployed, authenticate as the configured administrator and run read-only
  smoke checks for catalog, bulk target analysis, and effective budgets.
- [ ] Run one idempotent fixture-backed Whiterabbit submission and one fixture-
  backed Ansible launch/cancel only when the environment is explicitly a safe
  test deployment; otherwise leave those production-checklist items unclaimed.
- [x] Prove secrets, delete routes, settings, provider profiles, users, roles,
  tokens, runner callbacks, and executor callbacks are absent from the model
  catalog.
- [x] Re-run `git diff --check`, catalog/API parity, complete Rails tests,
  complete Go tests, and provider tests immediately before reporting completion.
