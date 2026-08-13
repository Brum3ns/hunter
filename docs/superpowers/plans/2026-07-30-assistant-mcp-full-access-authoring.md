# Assistant MCP Full-Access Reading and Permission-Free Authoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Hunter chat read all useful non-secret domain data and create or explicitly edit any validated Whiterabbit template or Ansible playbook without a permission prompt, while preserving strict create conflicts, optimistic locking, no delete/run capability, and zero extra steps after `docker compose up --build` on the existing deployment.

**Architecture:** Keep dedicated Rails machine endpoints and dedicated MCP tools. Repair write scopes through grant introspection, add closed PATCH edit tools that validate the merged artifact, expand explicit secret-safe projections, and expose exactly the reviewed 24 chat tools to Claude. Existing Control Center persistence services remain the only database write boundary.

**Tech Stack:** Ruby 3.3.6, Rails 8, PostgreSQL/MongoDB, Go 1.25, MCP Go SDK, Claude Code CLI, Minitest, Go testing, Docker Compose.

## Global Constraints

- Implement the approved design at `docs/superpowers/specs/2026-07-30-assistant-mcp-full-access-authoring-design.md`.
- Create never overwrites; a duplicate name returns `name_conflict` and requires a later explicit edit request.
- Permission-free editing applies to every existing Whiterabbit template and Ansible playbook.
- Every edit requires artifact ID plus `expected_lock_version` and validates the complete merged artifact.
- The Assistant must never delete, run, send, schedule, shell, browse arbitrary URLs, change settings, or access credentials/secret values.
- All tool and scope sets are closed and non-wildcard; environment configuration may narrow but never widen them.
- Preserve mandatory fail-closed `Assistant::DraftValidation::Whiterabbit` and `Assistant::DraftValidation::AnsibleStatic` validation.
- Persist only through `ControlCenter::Templates::Persist` and `ControlCenter::Ansible::Playbooks::Persist`, attributed to the human turn user.
- Audit metadata only; never audit prompts, commands, YAML, diffs, evidence bodies, or tool results.
- No database migration is required.
- Preserve unrelated existing worktree edits. Do not commit unless the operator asks.

---

## File structure

### Rails authorization and shared authoring

- Modify `web/app/services/assistant/grants/issuer.rb`: explicit legacy/chat read/create/edit tool sets and toggle-aware grants.
- Modify `web/app/models/assistant/turn_grant.rb`: add the two exact edit scopes.
- Modify `web/app/controllers/api/v1/assistant/machine/base_controller.rb`: expose write scopes, shared authoring rate/error/audit helpers, and `{id,name,lock_version}` responses.
- Create `web/app/services/assistant/machine/control_center/artifact_input.rb`: closed normalization for full create fields and partial edit changes.
- Modify the two machine artifact controllers and routes for PATCH edit actions.

### Go MCP and Claude

- Modify `assistant/mcp/internal/transport/transport.go`: closed `WriteScopes` grant field.
- Modify `assistant/mcp/internal/runner/runner.go`: authorize required scopes against the closed read/write union.
- Replace the create-only `assistant/mcp/internal/modules/ccwrite` implementation with create+edit tool contracts and dedicated output schemas.
- Modify `assistant/claude/cmd/hunter-assistant-claude/main.go`: exact 24-tool allowlist, narrowing-only env override, and accurate system policy.
- Modify `assistant/gateway/internal/mcp/client.go`: accept a catalog superset while requiring all six legacy tools and still refusing to call any others.

### Secret-safe reads

- Create `web/app/services/assistant/machine/sensitive_data.rb`: bounded, fail-closed sensitive-text/header/evidence sanitization.
- Expand the target, vulnerability, program, and Control Center projections without using raw `as_json`.
- Modify the corresponding machine controllers to pass the human turn user and complete safe filters.
- Update Go module exact keys/descriptions and nested output validation.

### Disclosure, contracts, and governance

- Modify Assistant settings serialization/update UI and panel disclosure.
- Update `web/config/openapi/assistant.yaml`, `AGENTS.md`, security checklist, and the live smoke runbook.
- Update catalog golden and all affected Rails/Go/JavaScript tests.

---

### Task 1: Repair write-scope authorization end to end

**Files:**

- Modify: `web/app/models/assistant/turn_grant.rb`
- Modify: `web/app/services/assistant/grants/issuer.rb`
- Modify: `web/app/services/assistant/turn_creator.rb`
- Modify: `web/app/controllers/api/v1/assistant/machine/base_controller.rb`
- Modify: `assistant/mcp/internal/transport/transport.go`
- Modify: `assistant/mcp/internal/runner/runner.go`
- Test: `web/test/models/assistant/turn_grant_test.rb`
- Test: `web/test/services/assistant/grants/issuer_test.rb`
- Test: `web/test/services/assistant/grants/authorizer_test.rb`
- Test: `web/test/integration/api/v1/assistant/machine/authorization_test.rb`
- Test: `assistant/mcp/internal/transport/transport_test.go`
- Test: `assistant/mcp/internal/runner/scope_adversarial_test.go`

**Interfaces:**

- Produces: `TurnGrant::WRITE_SCOPES = %w[control_center_templates_write control_center_templates_edit control_center_ansible_write control_center_ansible_edit]`.
- Produces: `Issuer::LEGACY_TOOLS`, `CHAT_READ_TOOLS`, `CHAT_CREATE_TOOLS`, `CHAT_EDIT_TOOLS`, `CHAT_TOOLS`.
- Produces: grant JSON field `write_scopes` and Go `transport.Grant.WriteScopes []string`.
- Consumes: existing turn binding, immutable JSONB scopes, global and authoring settings.

- [ ] **Step 1: Write failing Rails tests for exact tool/scopes and grant introspection**

Add assertions equivalent to:

```ruby
assert_equal %w[
  control_center_templates_write control_center_templates_edit
  control_center_ansible_write control_center_ansible_edit
], Assistant::TurnGrant::WRITE_SCOPES
assert_equal Assistant::Grants::Issuer::CHAT_TOOLS, grant.tools
assert_equal Assistant::TurnGrant::WRITE_SCOPES, response.parsed_body.fetch("write_scopes")
```

Also prove legacy turns receive only `LEGACY_TOOLS`, toggle-off grants receive no authoring tool/scope, and immutable scopes cannot be widened.

- [ ] **Step 2: Run the focused Rails tests and confirm the missing constants/field fail**

Run:

```sh
cd web && bin/rails test \
  test/models/assistant/turn_grant_test.rb \
  test/services/assistant/grants/issuer_test.rb \
  test/services/assistant/turn_creator_test.rb \
  test/integration/api/v1/assistant/machine/authorization_test.rb
```

Expected: failures for absent edit scopes/tool sets and absent `write_scopes` introspection.

- [ ] **Step 3: Implement exact Rails tool sets and introspection**

Use explicit constants, never derived prefixes:

```ruby
CHAT_TOOLS = (CHAT_READ_TOOLS + CHAT_CREATE_TOOLS + CHAT_EDIT_TOOLS).freeze
AUTHORING_TOOLS = (CHAT_CREATE_TOOLS + CHAT_EDIT_TOOLS).freeze
```

`TurnCreator` passes `CHAT_TOOLS` on Claude Code and `LEGACY_TOOLS` on the gateway path. `Issuer.call` strips all `AUTHORING_TOOLS` and returns no write scopes when `control_center_write_enabled?` is false. `grant_scope_payload` includes `write_scopes: grant.write_scopes`.

- [ ] **Step 4: Write failing Go transport/runner tests**

Add a complete introspection fixture containing `write_scopes`. Prove:

```go
grant := transport.Grant{
    Tools: []string{"create_whiterabbit_template"},
    WriteScopes: []string{"control_center_templates_write"},
    ExpiresAt: time.Now().Add(time.Minute), CallsRemaining: 8, BytesRemaining: 4096,
}
```

allows the write tool, while placing that slug only in `ReadScopes` or omitting it rejects with `ErrScopeDenied`.

- [ ] **Step 5: Run Go tests and confirm write authorization fails**

Run:

```sh
cd assistant/mcp && go test ./internal/transport ./internal/runner
```

Expected: compile/failing assertions because `WriteScopes` and write-aware authorization are absent.

- [ ] **Step 6: Implement closed Go write-scope transport and runner check**

Add `WriteScopes []string json:"write_scopes"` and change scope evaluation to an exact membership check over `append(copy(ReadScopes), WriteScopes...)`. Do not infer scope type from a suffix and do not accept wildcards.

- [ ] **Step 7: Run focused Rails and Go tests**

Expected: all Task 1 tests pass.

---

### Task 2: Normalize full artifact input and make create smooth

**Files:**

- Create: `web/app/services/assistant/machine/control_center/artifact_input.rb`
- Modify: `web/app/services/assistant/draft_envelope.rb`
- Modify: `web/app/controllers/api/v1/assistant/machine/control_center/templates_controller.rb`
- Modify: `web/app/controllers/api/v1/assistant/machine/control_center/ansible/playbooks_controller.rb`
- Modify: `web/app/controllers/api/v1/assistant/machine/base_controller.rb`
- Test: `web/test/services/assistant/machine/control_center/artifact_input_test.rb`
- Test: `web/test/integration/api/v1/assistant/machine/control_center/templates_create_test.rb`
- Test: `web/test/integration/api/v1/assistant/machine/control_center/ansible/playbooks_create_test.rb`

**Interfaces:**

- Produces: `ArtifactInput.whiterabbit_create(value)`, `.whiterabbit_changes(value)`, `.ansible_create(value)`, `.ansible_changes(value)` returning `Result(normalized:, codes:)`.
- Produces: absent Whiterabbit command `args` => `[]`; absent `operator` => `""`.
- Consumes: strict draft validators and existing persistence services.

- [ ] **Step 1: Write failing normalization tests**

Cover full create fields, command defaults, unknown field rejection, closed target fields, bounded tags/output/description, Ansible description/variable-set IDs, and no mutation of the input hash.

```ruby
result = ArtifactInput.whiterabbit_create(
  "name" => "httpx-proof", "kind" => "cmdscript",
  "commands" => [{ "command" => "httpx" }]
)
assert_equal [], result.normalized.dig("commands", 0, "args")
assert_equal "", result.normalized.dig("commands", 0, "operator")
```

- [ ] **Step 2: Run the new service test and confirm it fails because the service is absent**

Run: `cd web && bin/rails test test/services/assistant/machine/control_center/artifact_input_test.rb`

- [ ] **Step 3: Implement the closed normalizer**

Use exact key constants and bounded scalar/list helpers. Return stable codes only. Do not call `permit!`, preserve arbitrary hashes, or copy unknown nested keys.

- [ ] **Step 4: Add failing create integration tests**

Prove a command with only `command` creates successfully, full safe fields persist, Ansible description/variable-set IDs persist, a duplicate returns `name_conflict` without update, and invalid/secret content persists nothing.

- [ ] **Step 5: Refactor create controllers through `ArtifactInput`**

The controller validates the normalized complete candidate, persists a new record only, maps uniqueness to `name_conflict`, and returns `lock_version` in the bounded response. Keep the response accounting rule that never reports a committed create as 403.

- [ ] **Step 6: Run create, validator, persistence, and model tests**

Run:

```sh
cd web && bin/rails test \
  test/services/assistant/machine/control_center/artifact_input_test.rb \
  test/services/assistant/draft_validation/whiterabbit_test.rb \
  test/services/assistant/draft_validation/ansible_static_test.rb \
  test/services/control_center/templates/persist_test.rb \
  test/services/control_center/ansible/playbooks/persist_test.rb \
  test/integration/api/v1/assistant/machine/control_center/templates_create_test.rb \
  test/integration/api/v1/assistant/machine/control_center/ansible/playbooks_create_test.rb
```

Expected: pass.

---

### Task 3: Add permission-free, conflict-safe Rails edit endpoints

**Files:**

- Modify: `web/config/routes.rb`
- Modify: `web/app/services/assistant/rate_limiter.rb`
- Modify: `web/app/controllers/api/v1/assistant/machine/base_controller.rb`
- Modify: `web/app/controllers/api/v1/assistant/machine/control_center/templates_controller.rb`
- Modify: `web/app/controllers/api/v1/assistant/machine/control_center/ansible/playbooks_controller.rb`
- Test: `web/test/services/assistant/rate_limiter_test.rb`
- Create: `web/test/integration/api/v1/assistant/machine/control_center/templates_edit_test.rb`
- Create: `web/test/integration/api/v1/assistant/machine/control_center/ansible/playbooks_edit_test.rb`

**Interfaces:**

- Produces: PATCH routes at both artifact IDs.
- Produces: exact edit tools/scopes, stable `artifact_not_found`, `destination_stale`, `name_conflict`, `validation_failed`, `control_center_write_disabled`, and `authoring_rate_limited` outcomes.
- Consumes: Task 2 normalizers and existing `Persist` optimistic-lock API.

- [ ] **Step 1: Write failing route/edit happy-path tests**

For each artifact, issue PATCH with a valid grant, exact edit scope, current lock version, and one safe change. Assert 200, changed row, incremented lock version, same created-by attribution, and `machine.edit` audit metadata with no content.

- [ ] **Step 2: Add adversarial edit tests before implementation**

Cover absent/extra changes, wrong scope, switch off, stale version, missing ID, duplicate name, forbidden command/module, secret content, description-only revalidation, rate limit, and an unexpected persist exception. Every failure asserts the row is unchanged.

- [ ] **Step 3: Run edit tests and confirm 404/no-route failures**

Run:

```sh
cd web && bin/rails test \
  test/integration/api/v1/assistant/machine/control_center/templates_edit_test.rb \
  test/integration/api/v1/assistant/machine/control_center/ansible/playbooks_edit_test.rb
```

- [ ] **Step 4: Implement shared authoring rate/audit/error helpers**

Add an `edit` rate-limit action with its own bucket names but the existing hard authoring ceilings. Ensure every controller rejection releases its reservation and records only stable metadata.

- [ ] **Step 5: Implement template edit**

Load by integer ID, combine normalized changes with an explicit current-state hash, validate the complete candidate, then call:

```ruby
ControlCenter::Templates::Persist.call(
  record: template, attributes: candidate, user: machine_user,
  expected_lock_version: expected_lock_version
)
```

Never call `update!`, `assign_attributes` outside the persist service, or find by name.

- [ ] **Step 6: Implement playbook edit**

Follow the same pipeline with `yaml_content` mapped from the tool's `source`, preserving variable sets when absent and replacing them only when explicitly present.

- [ ] **Step 7: Run all edit/create/grant/rate tests**

Expected: pass with no create-to-edit path.

---

### Task 4: Add MCP edit tools and exact write output contracts

**Files:**

- Modify: `assistant/mcp/internal/modules/ccwrite/module.go`
- Modify: `assistant/mcp/internal/modules/ccwrite/schema.go`
- Modify: `assistant/mcp/internal/modules/ccwrite/output.go`
- Modify: `assistant/mcp/internal/modules/ccwrite/module_test.go`
- Modify: `assistant/mcp/internal/runner/catalog_golden_test.go`
- Modify: `assistant/mcp/internal/runner/testdata/catalog_golden.json`

**Interfaces:**

- Produces: `edit_whiterabbit_template` and `edit_ansible_playbook` MCP tools.
- Produces: PATCH calls to the two ID routes, exact scopes, and exact result schema `{result:{correlation_id,<artifact>:{id,name,lock_version}}}`.
- Consumes: Task 1 write scopes and Task 2/3 Rails inputs.

- [ ] **Step 1: Write failing table-driven Go tests**

For all four tools, test exact name/method/path/scope/body. Add invalid cases for extra keys, empty changes, invalid IDs/versions, overlong fields, duplicate variable-set IDs, and malformed nested command/target values.

- [ ] **Step 2: Run ccwrite tests and confirm edit tools are absent**

Run: `cd assistant/mcp && go test ./internal/modules/ccwrite`

- [ ] **Step 3: Implement closed create/edit schemas and decoders**

Use separate input structs; do not reuse a generic map. Normalize optional command arrays/operator before marshal so Go and Rails produce identical request bodies.

- [ ] **Step 4: Implement exact output schemas/validators**

Require positive integer ID, non-empty bounded name, nonnegative lock version, UUID correlation, and no extra key at any level. Replace `tool.ResultSchema` for these tools with the dedicated schema.

- [ ] **Step 5: Update and review the catalog golden**

Regenerate mechanically with the test helper, review the four authoring entries, and assert there is no delete/run/update-generic tool.

- [ ] **Step 6: Run the MCP suite**

Run: `cd assistant/mcp && go test ./...`

Expected: pass.

---

### Task 5: Expose exactly 24 tools and correct Claude behavior

**Files:**

- Modify: `assistant/claude/cmd/hunter-assistant-claude/main.go`
- Modify: `assistant/claude/cmd/hunter-assistant-claude/main_test.go`
- Modify: `assistant/claude/internal/chat/chat.go`
- Modify: `assistant/claude/internal/chat/chat_test.go`

**Interfaces:**

- Produces: exact 24-name `defaultMCPTools` and narrowing-only env override.
- Produces: system policy for necessary reads, permission-free explicit create/edit, no overwrite/delete/run.
- Consumes: MCP tool names from Task 4.

- [ ] **Step 1: Replace read-only tests with exact reviewed-catalog tests**

Assert length 24, exact set equality, all names start `mcp__hunter__`, no built-ins, no delete/run names, and both edit/create tools present.

- [ ] **Step 2: Add failing environment narrowing tests**

An override containing a valid subset plus `mcp__hunter__future_dangerous_tool`, `Bash`, and `mcp__other__x` must return only the valid reviewed subset. Duplicates must collapse while preserving reviewed order.

- [ ] **Step 3: Add failing system-policy content tests**

Require phrases/semantics for no permission prompt, explicit edit intent, no create overwrite, reads needed for action, and no delete/run. Remove the contradictory “read-only tools” claim.

- [ ] **Step 4: Implement the exact allowlist and policy**

Filter environment entries by membership in `defaultMCPTools`, not prefix. Keep `--strict-mcp-config`, temp-file permissions/cleanup, and built-in-tool denial unchanged.

- [ ] **Step 5: Run the Claude suite**

Run: `cd assistant/claude && go test ./...`

Expected: pass.

---

### Task 6: Make the optional legacy gateway tolerate the modular catalog safely

**Files:**

- Modify: `assistant/gateway/internal/mcp/client.go`
- Modify: `assistant/gateway/internal/mcp/client_test.go`
- Modify: `assistant/gateway/internal/provider/tools.go`
- Test: `assistant/gateway/internal/provider/contract_test.go`

**Interfaces:**

- Produces: catalog verification that requires each fixed legacy tool exactly once but permits unrelated advertised tools.
- Preserves: `Session.Call` only accepts `FixedToolNames()`.

- [ ] **Step 1: Write failing catalog-superset tests**

The six required names plus read/create/edit names must connect. Missing or duplicate required names must fail. `Session.Call("create_whiterabbit_template", ...)` must still fail locally.

- [ ] **Step 2: Run the gateway MCP tests and confirm superset rejection**

Run: `cd assistant/gateway && go test ./internal/mcp ./internal/provider`

- [ ] **Step 3: Implement required-subset verification**

Count names; require every fixed tool once. Do not treat unknown tools as callable and do not forward them to providers.

- [ ] **Step 4: Run the complete gateway suite**

Run: `cd assistant/gateway && go test ./...`

Expected: pass.

---

### Task 7: Expand secret-safe domain reads

**Files:**

- Create: `web/app/services/assistant/machine/sensitive_data.rb`
- Modify: `web/app/services/assistant/machine/target_projection.rb`
- Modify: `web/app/services/assistant/machine/vulnerability_projection.rb`
- Modify: `web/app/services/assistant/machine/program_projection.rb`
- Modify: `web/app/services/assistant/machine/control_center/template_projection.rb`
- Modify: `web/app/services/assistant/machine/control_center/job_projection.rb`
- Modify: `web/app/services/assistant/machine/control_center/ansible/playbook_projection.rb`
- Modify: affected machine controllers under `web/app/controllers/api/v1/assistant/machine/`
- Modify: affected Go modules under `assistant/mcp/internal/modules/`
- Test: create `web/test/services/assistant/machine/sensitive_data_test.rb`
- Test: modify module integration tests under `web/test/integration/api/v1/assistant/machine/`
- Test: modify Go module/runner tests.

**Interfaces:**

- Produces: `SensitiveData.text(value) -> {value:, redacted:}` and `SensitiveData.headers(hash) -> [{name:,value:}]` with fixed caps.
- Produces: expanded exact projection keys listed in the design.
- Consumes: `machine_user` for program state; existing module queries and filters.

- [ ] **Step 1: Write sanitizer adversarial tests**

Cover Authorization/Proxy-Authorization, Cookie/Set-Cookie, API keys, bearer/basic tokens, private keys, cloud keys, URL userinfo, credential assignments, JWT-like values, invalid UTF-8, control bytes, oversized text, header count/name/value caps, and ordinary HTTP evidence. Unsafe material must never survive in returned values.

- [ ] **Step 2: Implement the bounded fail-closed sanitizer**

Use fixed sensitive-header names and explicit regex replacements. Re-run `Assistant::Context::SecretDetector.detect` on sanitized output; if still unsafe, return `value: nil, redacted: true`.

- [ ] **Step 3: Add projection/controller failing tests module by module**

Targets: normalized probe fields and safe headers. Vulnerabilities: sanitized evidence and flags. Programs: full safe fields plus current user's favorite/trash/view state and missing web filters. Control Center: lock versions/attribution and no secret values.

- [ ] **Step 4: Implement explicit projections and user-scoped program query**

Never call raw `as_json`; enumerate every returned key. Pass `machine_user.favorite_sids` and `trash_sids` into `Programs::Query`. Obtain `last_viewed_at` only from that user.

- [ ] **Step 5: Update Go exact keys, descriptions, and nested validators**

Keep input schemas closed and sync every new Rails key. Add nested shape checks for evidence, headers, commands/targets, scope entries, and personal-state scalar types.

- [ ] **Step 6: Run focused Rails and Go read tests**

Run:

```sh
cd web && bin/rails test \
  test/services/assistant/machine/sensitive_data_test.rb \
  test/integration/api/v1/assistant/machine/targets_test.rb \
  test/integration/api/v1/assistant/machine/vulnerabilities_test.rb \
  test/integration/api/v1/assistant/machine/programs_test.rb \
  test/integration/api/v1/assistant/machine/control_center
cd ../assistant/mcp && go test ./internal/modules/... ./internal/runner
```

Expected: pass; secret fixtures are rejected/redacted with stable output.

---

### Task 8: Update settings, disclosure, OpenAPI, and governance

**Files:**

- Modify: `web/app/controllers/api/v1/assistant/base_controller.rb`
- Modify: `web/app/controllers/api/v1/assistant/settings_controller.rb`
- Modify: `web/app/views/settings/_assistant.html.erb`
- Modify: `web/app/views/layouts/_assistant.html.erb`
- Modify: `web/config/openapi/assistant.yaml`
- Modify: `web/test/integration/settings/assistant_test.rb`
- Modify: `web/test/integration/assistant_shell_test.rb`
- Modify: `web/test/integration/api/v1/openapi_test.rb`
- Modify: `AGENTS.md`
- Modify: `docs/security/hunter-assistant-threat-model.md`
- Modify: `docs/security/hunter-assistant-production-checklist.md`
- Modify: `docs/runbooks/assistant-claude-mcp-smoke-test.md`

**Interfaces:**

- Produces: serialized/audited `control_center_write_enabled` setting and accurate capability disclosure.
- Produces: OpenAPI PATCH/create/full-read contracts and governance reference to the approved delta.

- [ ] **Step 1: Write failing settings/disclosure/OpenAPI tests**

Prove the setting is returned, only the session administrator can change it, enable/disable uses audited model methods, and UI copy says non-secret reads + create/explicit edit without confirmation + no delete/run.

- [ ] **Step 2: Implement settings toggle and disclosure**

Do not raw-update the authoring boolean. Convert the form value to boolean and call the existing audited enable/disable methods.

- [ ] **Step 3: Document exact machine contracts**

Add PATCH routes, write scopes, lock versions, stable errors, and expanded projections to OpenAPI. Replace stale read-only/create-only wording in comments and runbooks.

- [ ] **Step 4: Record the approved exception and production evidence row**

Make `AGENTS.md` cite the new delta and state create+explicit edit conditions. Update the baseline threat model's draft-to-execution section without marking the production checklist passed.

- [ ] **Step 5: Run documentation/UI/OpenAPI tests**

Run:

```sh
cd web && bin/rails test \
  test/integration/settings/assistant_test.rb \
  test/integration/assistant_shell_test.rb \
  test/integration/api/v1/openapi_test.rb
```

Expected: pass.

---

### Task 9: Full verification and rebuild acceptance handoff

**Files:**

- Modify only files required by failures attributable to this feature.
- Do not modify or discard unrelated dirty files.

**Interfaces:**

- Produces: source-level and runtime verification evidence suitable for the operator.

- [ ] **Step 1: Run formatting/static checks**

Run:

```sh
git diff --check
gofmt -w assistant/mcp assistant/claude assistant/gateway
cd web && bin/rails zeitwerk:check
```

Review `git diff --stat` and `git status --short` to confirm unrelated files remain intact.

- [ ] **Step 2: Run complete automated suites**

Run:

```sh
cd web && bin/rails test
node --test test/javascript/*.mjs
cd ../assistant/mcp && go test -race ./...
cd ../claude && go test -race ./...
cd ../gateway && go test -race ./...
cd ../validator && go test -race ./...
```

Expected: all pass.

- [ ] **Step 3: Validate Compose/security structure where tooling is available**

Run:

```sh
docker compose config
docker compose -f docker-compose.prod.yaml config
ops/assistant/verify_compose_security.sh
ops/assistant/check_secret_leaks.sh
```

Do not print resolved secret values. If Docker is unavailable, record that exact environmental limitation and still run YAML/static checks that do not expose `.env` values.

- [ ] **Step 4: Live acceptance on the rebuilt stack**

After `docker compose up --build`, execute the nine acceptance cases in the approved design. Inspect only metadata-only audit rows and artifact IDs/names/versions; do not copy credentials or secret-bearing payloads into evidence.

- [ ] **Step 5: Final review**

Confirm no delete/run/generic tool exists, the exact Claude catalog has 24 tools, all authoring endpoints validate final state, create conflicts never edit, and production checklist items remain “Not run” unless real evidence was recorded.

## Plan self-review

- Spec coverage: every design section maps to Tasks 1–9.
- Placeholder scan: no TBD/TODO/“implement later” steps remain.
- Interface consistency: Rails and Go use the same four scope slugs, four authoring tool names, two PATCH routes, and `{id,name,lock_version}` result shape.
- Authorization consistency: read/write scope transport is fixed before authoring tools are enabled.
- Safety consistency: create never loads a row; edit always loads by ID and requires a lock version; no task adds delete/run/generic tools.
- Deployment consistency: no migration or manual post-build command is introduced.
