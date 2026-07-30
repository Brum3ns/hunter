# Assistant Approval-Free Create Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the Assistant LLM create (never edit/delete/run) new Whiterabbit templates and Ansible playbooks without the human confirm step, behind dedicated write authorization, an on-by-default independent toggle, and — mandatorily — the existing fail-closed content validators.

**Architecture:** Add a `write_scopes` concept to the turn grant + a `control_center_write_enabled` toggle to `Assistant::Setting`; the Issuer grants two `create_*` tools + `*_write` scopes only when the toggle is on; two new POST machine endpoints run the strict validators fail-closed and then create-only via the existing `Persist` services, attributed to the grant's turn user and audited; two Go MCP write tools copy the existing validation-POST shape.

**Tech Stack:** Ruby/Rails 8 (Postgres), Go 1.25 MCP (`assistant/mcp`), Minitest, `go test`.

## Global Constraints

- **Validators are mandatory and fail-closed.** Playbooks → `Assistant::DraftValidation::AnsibleStatic.call(source)`; templates → `Assistant::DraftValidation::Whiterabbit.call(attrs)`. `!result.valid?` ⇒ 422 with `result.codes`, **no persist**. Never bypass, never make optional.
- **Create-only, server-enforced:** endpoints only ever build `Model.new`; never load/update/delete; no execution. Duplicate unique name ⇒ 422 (enforces no-overwrite).
- **Scope = two artifact types only:** Whiterabbit templates, Ansible playbooks. No inventories/variable-sets/variables; no edit/update/delete/run; no allowlist changes.
- **Exact names (identical across Rails + Go):** tools `create_whiterabbit_template`, `create_ansible_playbook`; write scopes `control_center_templates_write`, `control_center_ansible_write`; routes `POST /api/v1/assistant/machine/control_center/templates` and `POST /api/v1/assistant/machine/control_center/ansible/playbooks`; toggle `Assistant::Setting#control_center_write_enabled` (default true).
- **Attribution:** `machine_user = machine_grant.turn.user` (a `User`). Passed as `user:` to the `Persist` services (`Templates::Persist` sets `created_by = user&.username`; `Playbooks::Persist` sets `created_by = user`).
- **Audit metadata-only:** `Assistant::Audit.record!` with keys ⊆ `Audit::ATTRIBUTE_KEYS`; `metadata` keys ⊆ `%w[operation reason limit outcome request_id source]`.
- Rails tests: `cd web && set -a; . ../.env; set +a; unset CONTROL_CENTER_COMMAND_ALLOWLIST; export DB_HOST=172.17.0.1 DB_PORT=5433 DB_DATABASE_TEST=hunter_test; bin/rails test <files>`. NOTE: several assistant tests require `CONTROL_CENTER_COMMAND_ALLOWLIST` and `ASSISTANT_ANSIBLE_MODULE_ALLOWLIST` to be SET (the validators need them) — set them per-test via `ENV`/`Config` stubbing as the existing draft-validation tests do; check `test/services/assistant/draft_validation/*_test.rb` for the pattern. Go tests: `cd assistant/mcp && go test ./...`. Commit author `Claude <noreply@anthropic.com>`, one-sentence messages. EXPLICIT `git add` paths only (unrelated user WIP is in `web/`).

---

### Task 1: Grant `write_scopes` column + model rules

**Files:**
- Create: `web/db/migrate/20260730100000_add_write_scopes_to_assistant_turn_grants.rb`
- Modify: `web/db/schema.rb` (regenerated), `web/app/models/assistant/turn_grant.rb`
- Test: `web/test/models/assistant/turn_grant_test.rb`

**Interfaces:**
- Produces: `assistant_turn_grants.write_scopes` (`jsonb`, default `[]`, not null); `TurnGrant::WRITE_SCOPES = %w[control_center_templates_write control_center_ansible_write].freeze`; `write_scopes` immutable on update; validation rejects unknown write-scope slugs.

- [ ] **Step 1: Migration** — `add_column :assistant_turn_grants, :write_scopes, :jsonb, default: [], null: false`. Run `cd web && bin/rails db:migrate` (schema version advances).
- [ ] **Step 2: Failing model tests** — mirror the existing `read_scopes` tests: (a) `write_scopes` defaults to `[]` and is immutable after issue (assigning then `save` fails, error on `:write_scopes`); (b) a grant with `write_scopes: ["bogus"]` is invalid with an error on `:write_scopes`; (c) `write_scopes: TurnGrant::WRITE_SCOPES` is valid.
- [ ] **Step 3: Run → FAIL.**
- [ ] **Step 4: Model** — add `WRITE_SCOPES = %w[control_center_templates_write control_center_ansible_write].freeze`; add `:write_scopes` to `IMMUTABLE_ATTRIBUTES`; add `validate :write_scopes_are_known` with `def write_scopes_are_known; extra = Array(write_scopes) - WRITE_SCOPES; errors.add(:write_scopes, "contains unknown slugs: #{extra.join(', ')}") if extra.any?; end`.
- [ ] **Step 5: Run → PASS.**
- [ ] **Step 6: Commit** — `git add web/db/migrate/20260730100000_add_write_scopes_to_assistant_turn_grants.rb web/db/schema.rb web/app/models/assistant/turn_grant.rb web/test/models/assistant/turn_grant_test.rb && git commit -m "Add the immutable write_scopes set to the Assistant turn grant."`

---

### Task 2: `control_center_write_enabled` toggle on `Assistant::Setting`

**Files:**
- Create: `web/db/migrate/20260730100100_add_control_center_write_enabled_to_assistant_settings.rb`
- Modify: `web/db/schema.rb`, `web/app/models/assistant/setting.rb`
- Test: `web/test/models/assistant/setting_test.rb` (create if absent)

**Interfaces:**
- Produces: `assistant_settings.control_center_write_enabled` (`boolean`, default `true`, not null); `Assistant::Setting#control_center_write_enabled?`; class helpers `enable_control_center_write!` / `disable_control_center_write!(user:)` that flip the flag and audit.

- [ ] **Step 1: Migration** — `add_column :assistant_settings, :control_center_write_enabled, :boolean, default: true, null: false`. Migrate.
- [ ] **Step 2: Failing tests** — `Assistant::Setting.instance.control_center_write_enabled?` is `true` by default; `disable_control_center_write!(user: users(:someone))` makes it false and writes an `Assistant::AuditEvent` (`event: "control_center_write.disabled"`); `enable_control_center_write!` flips it back (`event: "control_center_write.enabled"`).
- [ ] **Step 3: Run → FAIL.**
- [ ] **Step 4: Model** — add instance methods `enable_control_center_write!` (`update!(control_center_write_enabled: true)` + `Assistant::Audit.record!(event: "control_center_write.enabled", attributes: {metadata: {operation: "control_center_write", outcome: "enabled"}})`) and `disable_control_center_write!(user:)` (symmetric, `outcome: "disabled"`, `user_id: user&.id`), plus class delegators. Ensure `Audit::ATTRIBUTE_KEYS` already permits `user_id`/`metadata` (it does).
- [ ] **Step 5: Run → PASS.**
- [ ] **Step 6: Commit** — explicit paths; `git commit -m "Add the on-by-default control_center_write_enabled toggle to Assistant settings."`

---

### Task 3: Issuer grants create tools + write scopes (toggle-aware); Authorizer checks write scope

**Files:**
- Modify: `web/app/services/assistant/grants/issuer.rb`, `web/app/services/assistant/grants/authorizer.rb`
- Test: `web/test/services/assistant/grants/issuer_test.rb`, `web/test/services/assistant/grants/authorizer_test.rb`

**Interfaces:**
- Consumes: `TurnGrant::WRITE_SCOPES`, `Assistant::Setting#control_center_write_enabled?`.
- Produces: `Issuer::TOOLS` includes `create_whiterabbit_template`, `create_ansible_playbook`; `Issuer.call` sets `write_scopes: setting_on? ? TurnGrant::WRITE_SCOPES : []` and includes the two create tools in the persisted `tools` only when the toggle is on; `Authorizer#authorize!` allows a required `scope` if it is in `grant.read_scopes` **or** `grant.write_scopes`.

- [ ] **Step 1: Failing tests.** Issuer: with `Assistant::Setting.instance.control_center_write_enabled? == true`, an issued grant has `write_scopes == TurnGrant::WRITE_SCOPES` and its `tools` include both `create_*` tools; with the toggle off, `write_scopes == []` and neither create tool is in `tools` (even though they are in `Issuer::TOOLS`). Authorizer: `reserve!(tool: "create_ansible_playbook", scope: "control_center_ansible_write")` succeeds for a grant whose `write_scopes` include it (build the grant like the existing authorizer tests do), and raises `AuthorizationError("scope_not_allowed")` when `write_scopes == []`.
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Issuer.** Append the two create-tool names to `TOOLS`. In `call`, compute `write_enabled = Assistant::Setting.instance.control_center_write_enabled?`; set `write_scopes: write_enabled ? Assistant::TurnGrant::WRITE_SCOPES : []` on the `TurnGrant.create!`; and filter the granted `tools` so the two `create_*` tools are included only when `write_enabled` (e.g. build the tool list from the passed `tools`, then `reject { |t| CREATE_TOOLS.include?(t) } unless write_enabled`, where `CREATE_TOOLS = %w[create_whiterabbit_template create_ansible_playbook]`). Keep `normalize_tools` validating against `TOOLS`.
- [ ] **Step 4: Authorizer.** In `authorize!`, change the scope gate to: `if scope.present? && !(grant.read_scopes.include?(scope) || grant.write_scopes.include?(scope)); raise AuthorizationError, "scope_not_allowed"; end`.
- [ ] **Step 5: Run → PASS.**
- [ ] **Step 6: Commit** — explicit paths; `git commit -m "Grant the Control Center create tools and write scopes when the write toggle is on, and authorize write scopes."`

---

### Task 4: Machine write helpers + RateLimiter create action

**Files:**
- Modify: `web/app/controllers/api/v1/assistant/machine/base_controller.rb`, `web/app/services/assistant/rate_limiter.rb`
- Test: `web/test/services/assistant/rate_limiter_test.rb`, and the helpers are exercised by Tasks 5-6.

**Interfaces:**
- Produces on `Machine::BaseController` (private): `machine_user` → `machine_grant.turn.user`; `require_control_center_write_enabled!(reservation)` → if `!Assistant::Setting.instance.control_center_write_enabled?` then `reservation.fail!` and `render json: { error: "control_center_write_disabled" }, status: :forbidden` and return `false`, else `true`; `machine_create_response(reservation, key:, record:)` → `complete_machine_response!(reservation, { correlation_id: machine_grant.turn.correlation_id, key => { id: record.id, name: record.name } })`; `render_machine_validation_error(reservation, codes)` → `reservation.fail!; render json: { error: "validation_failed", codes: codes }, status: :unprocessable_content`; `render_machine_create_error(reservation, errors)` → `reservation.fail!; render json: { error: "create_rejected", errors: errors }, status: :unprocessable_content`.
- Produces on `RateLimiter`: a `create` action branch bounding creates per user over a per-minute + per-hour window (reuse `consume_window!`), raising `LimitExceeded(code: "create_rate_limited", retry_after_seconds:)`; caps from `Config` (`max_creates_per_minute`, `max_creates_per_hour`) with `bounded_ceiling` defaults (e.g. 5/min, 30/hour).

- [ ] **Step 1: Failing RateLimiter test** — `RateLimiter.consume!(user:, action: "create")` allows up to the per-minute cap, then raises `LimitExceeded` with `code == "create_rate_limited"` and a positive `retry_after_seconds`. Mirror the existing `turn_start` window test.
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** the `create` action branch in `RateLimiter.consume!` (mirror `turn_start`'s per-minute/per-hour `consume_window!` calls, minus the concurrency check) and add the two `Config` caps with `bounded_ceiling`. Add the four helpers to `Machine::BaseController`. `render_machine_validation_error`/`create_error` use `:unprocessable_content` (Rails 8 status symbol; the codebase uses it elsewhere).
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit** — explicit paths; `git commit -m "Add machine write helpers and a per-user create rate limit."`

---

### Task 5: Whiterabbit template create endpoint

**Files:**
- Create: (none — add `create` to the existing controller) — Modify `web/app/controllers/api/v1/assistant/machine/control_center/templates_controller.rb`, `web/config/routes.rb`
- Test: `web/test/integration/api/v1/assistant/machine/control_center/templates_create_test.rb`

**Interfaces:**
- Consumes: `authorize_tool!`, `require_control_center_write_enabled!`, `machine_user`, `machine_create_response`, `render_machine_validation_error`, `render_machine_create_error` (Task 4); `RateLimiter.consume!` (Task 4); `DraftEnvelope.whiterabbit`, `DraftValidation::Whiterabbit.call`, `ControlCenter::Templates::Persist.call`, `Assistant::Audit.record!`.
- Produces: `POST /api/v1/assistant/machine/control_center/templates` → `{correlation_id, template: {id, name}}` (201). Input body `{template: {name, kind, description?, commands}}`.

- [ ] **Step 1: Route** — inside the machine `namespace :control_center` block, add `post "templates", to: "templates#create"` (next to the existing `get "templates"`).
- [ ] **Step 2: Failing integration tests** — with the write toggle on, a grant carrying `write_scopes: ["control_center_templates_write"]` + the `create_whiterabbit_template` tool, `CONTROL_CENTER_COMMAND_ALLOWLIST` set to include e.g. `curl`, and a machine-auth header helper (reuse the read tests' helper): (a) POST a valid `cmdscript` template with a single `curl` command → 201, response `{correlation_id, template:{id,name}}`, a `ControlCenter::Template` row exists with `created_by == machine_user.username`, and an `Assistant::AuditEvent` with `event == "machine.create"` and `metadata["operation"] == "create_whiterabbit_template"`; (b) a command NOT in the allowlist → 422 `validation_failed`, no row created; (c) duplicate name (seed one) → 422 `create_rejected`, no second row; (d) grant without the write scope → 403/`scope_not_allowed` (from authorize_tool!); (e) toggle off → 403 `control_center_write_disabled`.
- [ ] **Step 3: Run → FAIL.**
- [ ] **Step 4: Implement `#create`:**

```ruby
def create
  reservation = authorize_tool!("create_whiterabbit_template", scope: "control_center_templates_write")
  return unless require_control_center_write_enabled!(reservation)

  begin
    ::Assistant::RateLimiter.consume!(user: machine_user, action: "create")
  rescue ::Assistant::RateLimiter::LimitExceeded => e
    reservation.fail!
    return render json: { error: e.code, retry_after: e.retry_after_seconds }, status: :too_many_requests
  end

  attrs = ::Assistant::DraftEnvelope.whiterabbit(params[:template])
  return render_machine_validation_error(reservation, [ "whiterabbit_template_invalid" ]) if attrs.nil?

  result = ::Assistant::DraftValidation::Whiterabbit.call(attrs)
  return render_machine_validation_error(reservation, result.codes) unless result.valid?

  persist = ::ControlCenter::Templates::Persist.call(
    record: ::ControlCenter::Template.new, attributes: attrs, user: machine_user
  )
  return render_machine_create_error(reservation, persist.errors) unless persist.success?

  ::Assistant::Audit.record!(event: "machine.create", attributes: {
    correlation_id: machine_grant.turn.correlation_id, user_id: machine_user&.id,
    target_type: "control_center_whiterabbit_template", target_id: persist.record.id,
    metadata: { operation: "create_whiterabbit_template", outcome: "created" }
  })
  machine_create_response(reservation, key: :template, record: persist.record)
end
```

Confirm `DraftEnvelope.whiterabbit` returns the normalized attrs hash on success and `nil`/blank on invalid shape (read it; if it raises instead, rescue to the validation error). Confirm `Audit::ATTRIBUTE_KEYS` includes `correlation_id, user_id, target_type, target_id, metadata` (it does per the audit service).

- [ ] **Step 5: Run → PASS** (full `templates_create_test.rb`).
- [ ] **Step 6: Commit** — `git add web/app/controllers/api/v1/assistant/machine/control_center/templates_controller.rb web/config/routes.rb web/test/integration/api/v1/assistant/machine/control_center/templates_create_test.rb && git commit -m "Add the approval-free Whiterabbit template create machine endpoint."`

---

### Task 6: Ansible playbook create endpoint

**Files:**
- Modify: `web/app/controllers/api/v1/assistant/machine/control_center/ansible/playbooks_controller.rb`, `web/config/routes.rb`
- Test: `web/test/integration/api/v1/assistant/machine/control_center/ansible/playbooks_create_test.rb`

**Interfaces:**
- Consumes: same helpers/services; `DraftEnvelope.ansible` (fields `name`, `source`), `DraftValidation::AnsibleStatic.call(source)`, `ControlCenter::Ansible::Playbooks::Persist.call`.
- Produces: `POST /api/v1/assistant/machine/control_center/ansible/playbooks` → `{correlation_id, playbook: {id, name}}` (201). Input body `{playbook: {name, source}}`.

- [ ] **Step 1: Route** — inside the machine `namespace :control_center { namespace :ansible { … } }` block add `post "playbooks", to: "playbooks#create"`.
- [ ] **Step 2: Failing integration tests** — with the toggle on, a grant with `write_scopes: ["control_center_ansible_write"]` + `create_ansible_playbook` tool, and `ASSISTANT_ANSIBLE_MODULE_ALLOWLIST` set to include e.g. `ansible.builtin.debug`: (a) a valid playbook using only an allowlisted module → 201, `ControlCenter::Ansible::Playbook` row with `created_by == machine_user`, audit `operation == "create_ansible_playbook"`; (b) a playbook with `ansible.builtin.shell` → 422 `validation_failed` (code `ansible_module_not_allowed`), no row; (c) a playbook containing an obvious secret / a `http://…` URL → 422; (d) grant without the write scope → 403; (e) toggle off → 403 `control_center_write_disabled`. Build valid/invalid YAML strings inline.
- [ ] **Step 3: Run → FAIL.**
- [ ] **Step 4: Implement `#create`** mirroring Task 5, but:

```ruby
def create
  reservation = authorize_tool!("create_ansible_playbook", scope: "control_center_ansible_write")
  return unless require_control_center_write_enabled!(reservation)

  begin
    ::Assistant::RateLimiter.consume!(user: machine_user, action: "create")
  rescue ::Assistant::RateLimiter::LimitExceeded => e
    reservation.fail!
    return render json: { error: e.code, retry_after: e.retry_after_seconds }, status: :too_many_requests
  end

  attrs = ::Assistant::DraftEnvelope.ansible(params[:playbook])
  return render_machine_validation_error(reservation, [ "ansible_source_invalid" ]) if attrs.nil?

  result = ::Assistant::DraftValidation::AnsibleStatic.call(attrs[:source])
  return render_machine_validation_error(reservation, result.codes) unless result.valid?

  persist = ::ControlCenter::Ansible::Playbooks::Persist.call(
    record: ::ControlCenter::Ansible::Playbook.new,
    attributes: { name: attrs[:name], yaml_content: attrs[:source] }, user: machine_user
  )
  return render_machine_create_error(reservation, persist.errors) unless persist.success?

  ::Assistant::Audit.record!(event: "machine.create", attributes: {
    correlation_id: machine_grant.turn.correlation_id, user_id: machine_user&.id,
    target_type: "control_center_ansible_playbook", target_id: persist.record.id,
    metadata: { operation: "create_ansible_playbook", outcome: "created" }
  })
  machine_create_response(reservation, key: :playbook, record: persist.record)
end
```

Note: the ansible envelope carries only `name`+`source` (no description) — do not pass a description. Confirm `attrs[:source]`/`attrs[:name]` are the envelope's normalized keys (read `DraftEnvelope.ansible`; adapt the key access to its actual return shape — string vs symbol keys).

- [ ] **Step 5: Run → PASS.**
- [ ] **Step 6: Commit** — explicit paths; `git commit -m "Add the approval-free Ansible playbook create machine endpoint."`

---

### Task 7: Go MCP write tools (`ccwrite`)

**Files:**
- Create: `assistant/mcp/internal/modules/ccwrite/module.go`, `schema.go`, `output.go`, `module_test.go`
- Modify: `assistant/mcp/cmd/hunter-mcp/main.go`, `assistant/mcp/internal/runner/catalog_golden_test.go`, `assistant/mcp/internal/runner/testdata/catalog_golden.json`

**Interfaces:**
- Consumes: `tool`, `codec`. Study `assistant/mcp/internal/modules/validation/{validation.go,schema.go}` — the exact POST-tool precedent (closed input schema → `codec.DecodeClosed` + a Go pre-check → `json.Marshal` body under 64 KiB → `tool.Call{Method:"POST", Path, Body}`).
- Produces: `ccwrite.Module{}` with `create_whiterabbit_template` (`Scope: "control_center_templates_write"`, POST `/api/v1/assistant/machine/control_center/templates`, closed input `{template:{name,kind,description?,commands}}` mirroring the validation module's whiterabbit draft schema) and `create_ansible_playbook` (`Scope: "control_center_ansible_write"`, POST `/api/v1/assistant/machine/control_center/ansible/playbooks`, closed input `{playbook:{name,source}}`, source maxLength 65536). Each `Validate` (output) accepts the closed `{correlation_id, <artifact>:{id (integer), name (string)}}` envelope and rejects extra keys.

- [ ] **Step 1: Failing Go tests** (`module_test.go`, black-box on `Module{}.Tools()`): scope per tool; a valid input decodes and `BuildRequest` yields `Method=="POST"`, the right `Path`, and a non-empty `Body`; an unknown input field is rejected; a valid output envelope validates and one with an extra key is rejected.
- [ ] **Step 2: Run → FAIL** (`cd assistant/mcp && go test ./internal/modules/ccwrite/`).
- [ ] **Step 3: Implement** the four files, copying the validation module's structure (closed `additionalProperties:false` schemas; `codec.DecodeClosed`; `buildCreate(path)` marshals the payload, enforces `len(body) <= 64<<10`, returns the POST `tool.Call`). Output validators mirror the readmodule `validateGet` exact-keys style: root keys `{correlation_id, <artifact>}`, correlation_id UUID, `<artifact>` closed with exactly `{id, name}`.
- [ ] **Step 4: Run → PASS**; `gofmt -l internal/modules/ccwrite/` empty; `go vet ./internal/modules/ccwrite/` clean.
- [ ] **Step 5: Register** `ccwrite.Module{}` in `cmd/hunter-mcp/main.go`'s `registry.Add(...)` (+ import) and in `catalog_golden_test.go`; add the two tools to `testdata/catalog_golden.json` (name/description/input_schema/output_schema, normalized as the other entries). Run `go test ./internal/runner/ -run 'TestCatalogMatchesGolden|TestAdversarialToolInputFixtures'` → PASS (28 tools; the adversarial fixture's dangerous names like `execute_playbook` still map to `unknown_tool` — our tools are `create_ansible_playbook`/`create_whiterabbit_template`, which are NOT in the dangerous-name fixture; confirm they aren't, and if the fixture happens to list `create_*` names, that fixture asserts they map to a real tool now — check and update the fixture expectation only if needed).
- [ ] **Step 6: Full Go** — `go build ./... && go test ./... && go vet ./... && gofmt -l .` clean.
- [ ] **Step 7: Commit** — `git add assistant/mcp/internal/modules/ccwrite/ assistant/mcp/cmd/hunter-mcp/main.go assistant/mcp/internal/runner/catalog_golden_test.go assistant/mcp/internal/runner/testdata/catalog_golden.json && git commit -m "Add the create_whiterabbit_template and create_ansible_playbook MCP write tools."`

---

### Task 8: Disclosure + capability-rule amendment

**Files:**
- Modify: `web/app/views/layouts/_assistant.html.erb`, `web/app/views/settings/_assistant.html.erb`, `web/test/integration/assistant_shell_test.rb`, `AGENTS.md`, `CLAUDE.md` (if it duplicates the rule; otherwise AGENTS.md is the source), `docs/security/hunter-assistant-production-checklist.md`
- Test: the disclosure presence test.

**Interfaces:** none (docs/UI).

- [ ] **Step 1: Disclosure copy.** In `_assistant.html.erb`'s `#hunter-assistant-capability-disclosure`, replace the current sentence with one that: keeps "read-only tools" for reads, and adds that **when Control Center write is enabled** the assistant can **create (not edit, delete, or run)** new *validated* Whiterabbit templates and Ansible playbooks, attributed to you and audited; everything else still requires your confirmation. Keep the substrings the presence test asserts (`/read-only tools/i`) and update the test's second assertion to match the new "create (not edit, delete, or run)" wording (adjust `assistant_shell_test.rb:52` regex accordingly). Mirror the change in `settings/_assistant.html.erb`.
- [ ] **Step 2: Run the presence test** (env recipe) → PASS.
- [ ] **Step 3: Capability-rule amendment.** In `AGENTS.md` (the "Assistant capability change rule" section — and `CLAUDE.md` if it restates it), append a subsection "Approved exceptions" recording: create-only of Whiterabbit templates + Ansible playbooks is approved without the human-approval step, on the conditions that the strict validators (`AnsibleStatic`, `Whiterabbit`/`TemplateValidator`) remain mandatory fail-closed gates, it is create-only (no edit/delete/run), it is authorized by dedicated non-wildcard write scopes and independently revocable via `Assistant::Setting.control_center_write_enabled`, and production stays gated by the assistant security checklist. Cite the spec `docs/superpowers/specs/2026-07-30-assistant-approval-free-create-design.md`.
- [ ] **Step 4: Production checklist.** Add a row to `docs/security/hunter-assistant-production-checklist.md` for this capability (status UNSET) so its review evidence is tracked before production enablement.
- [ ] **Step 5: Commit** — explicit paths; `git commit -m "Disclose the approval-free create capability and record the capability-rule exception."`

---

### Task 9: Full verification

- [ ] **Step 1: Go** — `cd assistant/mcp && go test -count=1 ./... && go vet ./... && gofmt -l .` → all pass/clean; catalog golden + adversarial pass.
- [ ] **Step 2: Rails** — env recipe (allowlists SET where the validators need them); run `bin/rails test test/models/assistant/turn_grant_test.rb test/models/assistant/setting_test.rb test/services/assistant/grants/ test/services/assistant/rate_limiter_test.rb test/integration/api/v1/assistant/machine/` → PASS. Then the full suite with `CONTROL_CENTER_COMMAND_ALLOWLIST` unset (dev-env artifact) and record the count; expect 0 failures aside from that known artifact.
- [ ] **Step 3: Live smoke (best-effort).** If a stack is reachable at the docker gateway `:5000`, exercise a create end-to-end (mint a grant via the rake path or a test, POST a valid + an invalid playbook, confirm 201 + a row and 422 + no row). If no Docker/stack is reachable in this environment, record that the container smoke test is an operator gate and rely on the integration tests.
- [ ] **Step 4: No commit** — verification only.

---

## Self-Review

**Spec coverage:** write authorization (grant `write_scopes` + Issuer + Authorizer) → Tasks 1,3 ✓; toggle default-on independently revocable → Task 2 (+ Issuer gate Task 3, controller re-check Task 4/5/6) ✓; create endpoints with mandatory fail-closed validators + create-only + attribution + audit → Tasks 5,6 ✓; create quota → Task 4 ✓; MCP write tools + golden + adversarial → Task 7 ✓; disclosure + capability-rule amendment + checklist → Task 8 ✓; adversarial tests → Tasks 5,6,7 ✓; verification → Task 9 ✓.

**Placeholder scan:** controller `#create` bodies are given in full; scope slugs/tool names/routes/audit keys are literal; the only "read it and adapt" notes are the `DraftEnvelope` return-shape (symbol vs string keys) confirmations, which are explicit verify-then-match steps, not placeholders.

**Type consistency:** `write_scopes`/`WRITE_SCOPES`/`control_center_templates_write`/`control_center_ansible_write`/`create_whiterabbit_template`/`create_ansible_playbook`/`control_center_write_enabled`/`machine_user`/`machine_create_response` are used identically across Tasks 1-8. The Go tool paths equal the Rails routes.

**Note — validator mandate:** every persist in Tasks 5-6 is preceded by a fail-closed `DraftValidation` gate that returns 422 on `!valid?`; there is no code path that persists unvalidated content. This is the load-bearing safety property and must survive review unchanged.
