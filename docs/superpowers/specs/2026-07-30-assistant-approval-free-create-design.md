# Assistant Approval-Free Create (Whiterabbit templates + Ansible playbooks) — Design & Threat-Model Delta

**Status:** DRAFTED. Date: 2026-07-30. This is both the design and the threat-model delta the AGENTS.md/CLAUDE.md capability rule requires for a new write capability.

## Summary

Give the Assistant LLM the ability to **create** (never edit, delete, or run) new Whiterabbit (Control Center) templates and Ansible playbooks **without the human confirmed-save step** — but with the existing content validators kept as a mandatory fail-closed safety floor, a dedicated non-wildcard write authorization, create-only enforcement, an independent kill toggle, a create quota, and metadata-only audit. Scope is deliberately limited to the two artifact types that have strict, fail-closed validators; inventories and variable-sets/variables (weak/no static validator) are **excluded**.

## Approved exception (recorded for the capability rule)

The AGENTS.md/CLAUDE.md capability rule states every effectful operation needs "an explicit human-approval design." The operator has explicitly approved **waiving the human-approval step for create-only** of these two artifact types, on the conditions below. This delta records that exception; the CLAUDE.md rule is amended (Task in the plan) to cite it. Production enablement still rides on the existing assistant security checklist and master gates (`ASSISTANT_ENABLED`, the DB `assistant_enabled`, the two required allowlists) — this capability cannot be live in production until the assistant itself is.

## Non-negotiable conditions (what makes this safe enough to ship)

1. **Validators stay mandatory, fail-closed.** Playbooks pass `Assistant::DraftValidation::AnsibleStatic` (strict: default-deny module allowlist; rejects shell/command/raw/script/include*/import*, roles, collections, vars_prompt, environment, lookups/`with_*`, URLs, absolute paths, `..` traversal, and secret material; 64 KiB cap; hard-fails if the module allowlist is unconfigured). Templates pass `Assistant::DraftValidation::Whiterabbit` + `ControlCenter::TemplateValidator` (only `CONTROL_CENTER_COMMAND_ALLOWLIST` binaries; argv only, no shell; bounded). A non-`valid` result → 422, **no persist**. The model-level validators (`Playbook.yaml_is_safe`, `Template.commands_pass_validator`) run again on `save` as a second line.
2. **Create-only, server-enforced.** The endpoints only ever build a brand-new record (`Model.new`); they never load, update, or delete. A duplicate unique name → 422 (this is what enforces "no overwrite"). No execution path is added.
3. **Dedicated, non-wildcard write authorization, independently revocable** (below).
4. **On by default, but revocable without killing the assistant:** a new `Assistant::Setting.control_center_write_enabled` boolean, default `true`. Off → no write scopes are granted and the endpoints refuse.
5. **Create quota + budget:** the grant's existing per-turn call budget (≤8) bounds per-turn writes; a new `RateLimiter` `create` action bounds per-user creates over time.
6. **Metadata-only audit** of every create via `Assistant::Audit.record!`.
7. **Prompt-injection is acknowledged:** the same LLM reads untrusted attacker-controlled text via the read tools; the validators (constraining the module/command *vocabulary* to operator-curated allowlists) are the control that contains an injection steering the model toward harmful content. This is why they are non-negotiable.

## Architecture

### 1. Write authorization on the turn grant

- New immutable `write_scopes` jsonb column on `assistant_turn_grants` (default `[]`, not null), added to `TurnGrant::IMMUTABLE_ATTRIBUTES`.
- `TurnGrant::WRITE_SCOPES = %w[control_center_templates_write control_center_ansible_write].freeze` (the closed known set); a validation rejects unknown write-scope slugs, mirroring `read_scopes_are_known`.
- `Assistant::Grants::Issuer::TOOLS` gains `create_whiterabbit_template`, `create_ansible_playbook`.
- `Issuer.call` sets `write_scopes: Assistant::Setting.instance.control_center_write_enabled? ? TurnGrant::WRITE_SCOPES : []` and includes the two create tools in the granted `tools` **only when the toggle is on** (when off, the create tools are not granted and no write scope is granted — belt and suspenders).
- `Assistant::Grants::Authorizer#authorize!` scope check becomes: a required `scope` is allowed if it is in `grant.read_scopes` **or** `grant.write_scopes`. (Read tools pass read scopes; create tools pass their `_write` scope. Toggle-off grants carry neither the tool nor the write scope → `tool_not_allowed`/`scope_not_allowed`.)

### 2. Machine create endpoints (Rails — the safety core)

Two POST routes under the existing `namespace :assistant { namespace :machine { namespace :control_center { … } } }`:
- `post "templates", to: "templates#create"` → `Api::V1::Assistant::Machine::ControlCenter::TemplatesController#create`
- `namespace :ansible { post "playbooks", to: "playbooks#create" }` → `…::ControlCenter::Ansible::PlaybooksController#create`

Each `create` action, in order:
1. `reservation = authorize_tool!("create_<artifact>", scope: "control_center_<family>_write")` (grant auth + write-scope + call/byte budget; the machine `BaseController`'s `limit_request_body!` already caps the POST body at 64 KiB).
2. `require_control_center_write_enabled!(reservation)` — if `Assistant::Setting.instance.control_center_write_enabled?` is false, `reservation.fail!` + render 403 `control_center_write_disabled`.
3. `Assistant::RateLimiter.consume!(user: machine_user, action: "create")` — on `LimitExceeded`, `reservation.fail!` + 429 with `retry_after`.
4. Normalize input through the closed-schema `DraftEnvelope.whiterabbit`/`DraftEnvelope.ansible` (rejects unknown fields, enforces length/byte caps and `safe_string`). On envelope failure → `reservation.fail!` + 422.
5. **Strict validator (fail-closed):** templates → `Assistant::DraftValidation::Whiterabbit.call(attrs)`; playbooks → `Assistant::DraftValidation::AnsibleStatic.call(source)`. If `!result.valid?` → `reservation.fail!` + render 422 `{error: "validation_failed", codes: result.codes}`. **No persist.**
6. **Create-only persist** on a NEW record via the existing service:
   - templates: `ControlCenter::Templates::Persist.call(record: ControlCenter::Template.new, attributes: {name, kind, description, commands, target, output}, user: machine_user)`.
   - playbooks: `ControlCenter::Ansible::Playbooks::Persist.call(record: ControlCenter::Ansible::Playbook.new, attributes: {name, description, yaml_content: source}, user: machine_user)`.
   - `machine_user` = `machine_grant.turn.user` (the human whose conversation this is). On `!success?` (incl. duplicate-name uniqueness) → `reservation.fail!` + 422 with `persist.errors`.
7. `Assistant::Audit.record!(event: "machine.create", attributes: {correlation_id:, user_id: machine_user&.id, target_type: "control_center_<artifact>", target_id: record.id, metadata: {operation: "create_<artifact>", outcome: "created"}})` (metadata-only; keys within `Audit::ATTRIBUTE_KEYS`/`METADATA_KEYS`).
8. `complete_machine_response!(reservation, {correlation_id:, <artifact>: {id: record.id, name: record.name}})` (bounded projection).

`machine_user` helper on the machine `BaseController`: `machine_grant.turn.user`.
`require_control_center_write_enabled!` + `machine_write_response` helpers live on the machine `BaseController` (or a small `WriteController` base) so both write controllers share them; the read `index`/`show` on these controllers are unchanged.

### 3. MCP write tools (Go)

Two tools copying the existing `assistant/mcp/internal/modules/validation` POST shape (closed input schema → `json.Marshal` body under 64 KiB → `tool.Call{Method:"POST", Path, Body}`), in a new `internal/modules/ccwrite` package:
- `create_whiterabbit_template` — closed input `{template:{name, kind, description?, commands[]}}` (kind ∈ cmdscript/workflow; commands closed with the same bounds the validation tool uses), `Scope: "control_center_templates_write"`, `Path: /api/v1/assistant/machine/control_center/templates`.
- `create_ansible_playbook` — closed input `{playbook:{name, description?, source}}` (source maxLength 65536), `Scope: "control_center_ansible_write"`, `Path: /api/v1/assistant/machine/control_center/ansible/playbooks`.
- `Validate` (output) accepts the closed `{correlation_id, <artifact>:{id, name}}` envelope.
Registered in `cmd/hunter-mcp/main.go` + `catalog_golden_test.go`; catalog golden extended.

### 4. Config, disclosure, governance

- `Assistant::Setting` gains a `control_center_write_enabled` boolean column, default `true`, plus `enable_control_center_write!`/`disable_control_center_write!(user:)` and an audit event on change. `KillSwitch.disable!` already revokes all grants, so it revokes writes too.
- **UI disclosure** (`app/views/layouts/_assistant.html.erb`, `settings/_assistant.html.erb`): change from "cannot create, edit, delete, run, or send anything without your explicit confirmation" to state that, when Control Center write is enabled, the assistant **can create (but not edit, delete, or run) new *validated* Whiterabbit templates and Ansible playbooks**, attributed to you and audited; everything else still requires your confirmation. Update the presence test.
- **CLAUDE.md / AGENTS.md capability-rule amendment:** add a subsection recording this approved exception (create-only, two artifact types, validators mandatory, human-approval waived per operator decision, independently revocable via `control_center_write_enabled`, production still gated by the checklist).

## Testing

- **Adversarial (the rule mandates stable-outcome adversarial tests):**
  - playbook with a prohibited module (`shell`) → 422, not persisted;
  - playbook with secret material / a URL / absolute path → 422;
  - template with a non-allowlisted command → 422;
  - `control_center_write_enabled=false` → 403 (and Issuer grants no write scope/tool);
  - grant lacking the write scope → `scope_not_allowed`;
  - duplicate template name → 422 (no overwrite);
  - create-quota exceeded → 429;
  - a grant issued while toggle-off cannot create even if the toggle flips on mid-turn (immutable grant).
- **Rails integration** (stub nothing that matters; seed rows): each create endpoint happy-path (valid content → 201/persisted, audit event written, response is the bounded projection), plus the adversarial cases. No live executor.
- **Go:** the two write tools' closed input/output schemas + POST path building; catalog golden + adversarial-tool-fixture parity (the dangerous fixture names remain `unknown_tool`).
- **Grant/Issuer/Authorizer unit tests** for the write_scopes column, immutability, Issuer toggle behavior, and the Authorizer write-scope check.

## Rollout

Ships **on by default** (toggle defaults true) but inert in production until the assistant itself is enabled (existing checklist). Picked up on the next `hunter-mcp` + `web` rebuild (`docker compose up --build`). Revocable via the `control_center_write_enabled` toggle or the kill-switch.

## Explicitly out of scope

Inventories, variable-sets, variables (weak/no static validator — excluded per the operator decision); any edit/update/delete/run capability; widening any allowlist (operator-curated, unchanged).

## Self-review

Placeholder scan: exact service signatures, scope slugs, tool names, routes, audit keys, and validator classes are all named. Consistency: `write_scopes`/`WRITE_SCOPES`/the two `_write` scopes/the two `create_*` tools are used identically across the grant, Issuer, Authorizer, controllers, and Go tools. Scope: one cohesive subsystem (approval-free CC create), single plan. Ambiguity: create-only and validators-mandatory are stated as hard server-side constraints, not conventions.
