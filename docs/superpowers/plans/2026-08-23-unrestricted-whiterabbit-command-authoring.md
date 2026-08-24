# Unrestricted Whiterabbit Command Authoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove Whiterabbit executable-name allowlisting so the Control Center and Assistant accept every structurally valid command while retaining exact authorization, structural validation, secret-input detection, revocation, idempotency, attribution, and metadata-only audit.

**Architecture:** `ControlCenter::TemplateValidator` remains the single domain validator but stops consulting deployment configuration or classifying executable names. `Assistant::DraftValidation::Whiterabbit` delegates command structure to that validator, keeps closed-envelope and secret checks, and advances to validation version `whiterabbit-v2`; all existing browser and dedicated Assistant machine routes continue to use these shared services. Deployment configuration and UI disclosure are updated so no retired allowlist can silently narrow behavior and the arbitrary worker-execution consequence is explicit.

**Tech Stack:** Ruby 3.3.6, Rails 8, Minitest, JavaScript ES modules with Node's test runner, Docker Compose YAML, ERB/Tailwind views, Hunter MCP capability catalog.

**Spec:** `docs/superpowers/specs/2026-08-23-unrestricted-whiterabbit-command-authoring-design.md`

## Global Constraints

- Accept every non-empty Whiterabbit executable name, including scanners, shells, interpreters, privilege/container/file utilities, absolute paths, custom binaries, and future names.
- Continue rejecting empty commands, NUL/CR/LF, invalid operators, excessive commands/arguments, oversized Assistant command names/arguments, malformed YAML, unknown closed-schema fields, and recognizable secret material in Assistant input.
- Keep the existing dedicated MCP tools, exact non-wildcard scopes, service/turn/user binding, live tool/module/effect gates, budgets, idempotency, optimistic locking, human attribution, action receipts, output redaction, and metadata-only audit.
- Do not add a generic MCP shell, request, network, filesystem, database, or execution tool; arbitrary execution is reachable only by authoring and submitting a Whiterabbit template through existing dedicated tools.
- Do not change Ansible module policy, secret-bearing operations, Hunter record-deletion routes, governance operations, worker callbacks, or worker installation/runtime behavior.
- Advance `Assistant::DraftValidation::Whiterabbit::VALIDATION_VERSION` from `whiterabbit-v1` to `whiterabbit-v2` so previously reviewed drafts are stale until revalidated under the unrestricted policy.
- Historical plans/specifications remain historical evidence and are not rewritten; update only active source, configuration, runbooks, project context, disclosure, and production evidence.
- Preserve unrelated user work, including the untracked `.vscode/` directory.
- Per `AGENTS.md`, do not create commits unless the user separately asks; each task ends with a diff/test checkpoint instead of a commit.

---

### Task 1: Remove executable-name policy from the Control Center domain validator

**Files:**
- Modify: `web/test/services/control_center/template_validator_test.rb:15-57`
- Modify: `web/test/integration/api/v1/control_center/templates_yaml_test.rb:17-74`
- Modify: `web/app/services/control_center/template_validator.rb:1-63`

**Interfaces:**
- Consumes: template command arrays shaped as `{ "command" => String, "args" => Array, "operator" => String }`.
- Produces: `ControlCenter::TemplateValidator.call(commands) -> Array<String>` with no executable-name policy and no `allowlist` method.
- Preserves: `ALLOWED_OPERATORS`, `MAX_COMMANDS`, `MAX_ARGS`, `MAX_ARG_LENGTH`, and `FORBIDDEN_CHARS`.

- [ ] **Step 1: Replace the allowlist unit tests with a failing retired-setting regression**

Replace the default/allowlist cases in `template_validator_test.rb` with a single behavior test whose production mutation is “restore executable-name filtering”:

```ruby
test "accepts every structurally valid command even when the retired setting is present" do
  original = ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"]
  ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"] = "httpx"

  commands = %w[nuclei dalfox katana feroxbuster gowitness dnsx bash python sudo docker rm]
  commands << "/opt/tools/custom-scanner"

  commands.each do |name|
    assert_empty V.call([{ "command" => name, "args" => [], "operator" => "" }]), name
  end
ensure
  ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"] = original
end
```

Keep the existing empty-list, invalid-operator, placeholder, metacharacter, NUL/newline, and size-bound tests unchanged. Delete tests that call `V.allowlist`, because that interface is retired rather than changed.

- [ ] **Step 2: Replace both browser allowlist tests with failing unrestricted YAML behavior**

Use the public Control Center API so the test exercises parsing, shared validation, model persistence, and response behavior:

```ruby
test "a retired allowlist value cannot narrow YAML validation" do
  sign_in_as(@user)
  original = ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"]
  ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"] = "httpx"

  post "/api/v1/control_center/templates/validate_yaml",
    params: { yaml: "name: nuclei-crlf\ncommands:\n  - command: nuclei\n    args: [-tags, crlf]\n" },
    as: :json

  assert_response :success
  assert_equal true, response.parsed_body["valid"]
  assert_empty response.parsed_body["errors"]
ensure
  ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"] = original
end

test "create via YAML persists an arbitrary command despite a retired allowlist value" do
  sign_in_as(@user)
  original = ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"]
  ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"] = "httpx"

  post "/api/v1/control_center/templates",
    params: { yaml: "name: unrestricted-bash\ncommands:\n  - command: bash\n    args: [-c, 'printf ok']\n" },
    as: :json

  assert_response :created
  assert_equal "bash", ControlCenter::Template.find_by!(name: "unrestricted-bash").commands.first.fetch("command")
ensure
  ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"] = original
end
```

- [ ] **Step 3: Run the focused tests and verify RED**

Run from `web/`:

```bash
PATH=/opt/rbenv/shims:/usr/local/go/bin:$PATH DB_HOST=172.17.0.1 DB_PORT=5433 DB_DATABASE_TEST=hunter_test bin/rails test test/services/control_center/template_validator_test.rb test/integration/api/v1/control_center/templates_yaml_test.rb
```

Expected: failures report that commands such as `nuclei`/`bash` are not allowed while `CONTROL_CENTER_COMMAND_ALLOWLIST=httpx`.

- [ ] **Step 4: Remove allowlist parsing and enforcement from the production validator**

Delete `TemplateValidator.allowlist`, the `list = allowlist` local, and the executable-membership error. Update the security comment to describe the approved behavior:

```ruby
# Executable names are deliberately unrestricted. Whiterabbit passes name and
# args to Go's exec.Command without an implicit shell; selecting a shell or
# interpreter explicitly gives that program its ordinary semantics.
def call(commands)
  errors = []
  commands = Array(commands)
  errors << "at least one command is required" if commands.empty?
  errors << "too many commands (max #{MAX_COMMANDS})" if commands.size > MAX_COMMANDS

  commands.each_with_index do |raw, i|
    cmd = (raw || {}).to_h.transform_keys(&:to_s)
    name = cmd["command"].to_s
    args = Array(cmd["args"])
    operator = cmd["operator"].to_s

    errors << "commands[#{i}].command is required" if name.empty?
    errors << "commands[#{i}].command contains a forbidden character (NUL or newline)" if name.match?(FORBIDDEN_CHARS)
    errors << "commands[#{i}].operator #{operator.inspect} is invalid" unless ALLOWED_OPERATORS.include?(operator)
    errors << "commands[#{i}] has too many args (max #{MAX_ARGS})" if args.size > MAX_ARGS

    args.each_with_index do |arg, j|
      s = arg.to_s
      errors << "commands[#{i}].args[#{j}] is too long (max #{MAX_ARG_LENGTH})" if s.length > MAX_ARG_LENGTH
      errors << "commands[#{i}].args[#{j}] contains a forbidden character (NUL or newline)" if s.match?(FORBIDDEN_CHARS)
    end
  end
  errors
end
```

- [ ] **Step 5: Run the focused tests and verify GREEN**

Run the Step 3 command again.

Expected: both files pass; structural rejection tests remain green.

- [ ] **Step 6: Review the task diff**

```bash
git diff --check -- web/app/services/control_center/template_validator.rb web/test/services/control_center/template_validator_test.rb web/test/integration/api/v1/control_center/templates_yaml_test.rb
git diff -- web/app/services/control_center/template_validator.rb web/test/services/control_center/template_validator_test.rb web/test/integration/api/v1/control_center/templates_yaml_test.rb
```

Expected: no whitespace errors; no `allowlist` method or executable-membership branch remains.

---

### Task 2: Make Assistant Whiterabbit policy explicitly unrestricted and version it

**Files:**
- Modify: `web/test/services/assistant/draft_validation/whiterabbit_test.rb:3-91`
- Modify: `web/test/services/assistant/authoring_policy_test.rb:3-20`
- Modify: `web/test/integration/api/v1/assistant/machine/tools_test.rb:100-129`
- Modify: `web/app/services/assistant/draft_validation/whiterabbit.rb:1-53`
- Modify: `web/app/services/assistant/authoring_policy.rb:12-34`

**Interfaces:**
- Consumes: `Assistant::DraftEnvelope.whiterabbit(attributes)` normalized closed content.
- Produces: `Assistant::DraftValidation::Whiterabbit.call(attributes) -> Assistant::DraftValidation::Result` with `validation_version == "whiterabbit-v2"`.
- Produces: `Assistant::AuthoringPolicy.for("whiterabbit_template")` containing `command_policy: "unrestricted"`, no `command_allowlist`, and `required_validation: ["closed_schema", "secret_material", "template_validator"]`.

- [ ] **Step 1: Rewrite draft-validation tests around unrestricted command behavior**

Delete the unconfigured-policy and rejected-command tests. Replace them with:

```ruby
test "accepts an arbitrary command when a stale retired allowlist is present" do
  original = ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"]
  ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"] = "httpx"
  draft = VALID_DRAFT.deep_dup
  draft["commands"] = [
    { "command" => "bash", "args" => [ "-c", "printf ok" ], "operator" => "" }
  ]

  result = Assistant::DraftValidation::Whiterabbit.call(draft)

  assert result.valid?, result.codes.inspect
  assert_equal "bash", result.normalized.dig("commands", 0, "command")
  assert_equal "whiterabbit-v2", result.validation_version
  assert_empty result.codes
ensure
  ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"] = original
end
```

Update the normalized-draft test to expect `whiterabbit-v2` and call the real validator without stubbing `allowlist`. Retain the closed-schema test by stubbing only `TemplateValidator.call`, and retain the credential, no-persistence, and no-execution tests without allowlist stubs.

- [ ] **Step 2: Write the failing versioned authoring-policy test**

```ruby
test "returns the versioned unrestricted non-secret Whiterabbit policy" do
  policy = Assistant::AuthoringPolicy.for("whiterabbit_template")

  assert_equal 1, policy.fetch(:schema_version)
  assert_equal "whiterabbit-v2", policy.fetch(:validation_version)
  assert_equal "unrestricted", policy.fetch(:command_policy)
  refute policy.key?(:command_allowlist)
  assert_equal [ "closed_schema", "secret_material", "template_validator" ],
    policy.fetch(:required_validation)
  assert_equal [ "", "|", "&&", "||" ], policy.fetch(:operators)
  assert_equal %w[__TARGET_FILE__ __TARGET_STDIN__ __UUID__], policy.fetch(:placeholders)
  refute_includes policy.to_json, "secret_ref"
end
```

- [ ] **Step 3: Update the machine policy/validation integration expectation before production code**

In `machine/tools_test.rb`, remove the validator allowlist stub, assert
`policy.command_policy == "unrestricted"`, assert the `command_allowlist` key is absent, validate a `nuclei` draft, and expect `whiterabbit-v2`:

```ruby
assert_equal "unrestricted", response.parsed_body.dig("policy", "command_policy")
refute response.parsed_body.fetch("policy").key?("command_allowlist")
# validation request command: nuclei
assert_equal "whiterabbit-v2", response.parsed_body.dig("validation", "version")
```

- [ ] **Step 4: Run the policy tests and verify RED**

```bash
PATH=/opt/rbenv/shims:/usr/local/go/bin:$PATH DB_HOST=172.17.0.1 DB_PORT=5433 DB_DATABASE_TEST=hunter_test bin/rails test test/services/assistant/draft_validation/whiterabbit_test.rb test/services/assistant/authoring_policy_test.rb test/integration/api/v1/assistant/machine/tools_test.rb
```

Expected: current validation rejects `bash` under the stale environment value, still reports `whiterabbit-v1`, and exposes `command_allowlist` instead of `command_policy`.

- [ ] **Step 5: Simplify Assistant draft validation and advance its version**

Set the new version and remove both Assistant allowlist branches:

```ruby
VALIDATION_VERSION = "whiterabbit-v2"

def call(attributes)
  parsed = Assistant::DraftEnvelope.whiterabbit(attributes)
  return result(false, parsed.codes, parsed.messages) unless parsed.valid?
  if Assistant::Context::SecretDetector.detect(parsed.normalized)
    return result(false,
      [ "artifact_secret_material_not_allowed" ],
      [ "Draft contains prohibited secret material." ])
  end

  domain_errors = ControlCenter::TemplateValidator.call(parsed.normalized.fetch("commands"))
  if domain_errors.any?
    return result(false,
      [ "whiterabbit_template_invalid" ],
      [ "Draft does not satisfy the Whiterabbit template policy." ])
  end

  result(true, [], [], parsed.normalized)
end
```

Do not add replacement executable classification or configuration.

- [ ] **Step 6: Publish the explicit unrestricted authoring policy**

Change only the Whiterabbit policy fields:

```ruby
command_policy: "unrestricted",
required_validation: [ "closed_schema", "secret_material", "template_validator" ]
```

Retain the schema version, structural maxima, kinds, operators, and placeholders.

- [ ] **Step 7: Run the policy tests and verify GREEN**

Run the Step 4 command again.

Expected: all three files pass, including secret-input and no-persistence invariants.

- [ ] **Step 8: Review the task diff**

```bash
git diff --check -- web/app/services/assistant/draft_validation/whiterabbit.rb web/app/services/assistant/authoring_policy.rb web/test/services/assistant/draft_validation/whiterabbit_test.rb web/test/services/assistant/authoring_policy_test.rb web/test/integration/api/v1/assistant/machine/tools_test.rb
git diff -- web/app/services/assistant/draft_validation/whiterabbit.rb web/app/services/assistant/authoring_policy.rb web/test/services/assistant/draft_validation/whiterabbit_test.rb web/test/services/assistant/authoring_policy_test.rb web/test/integration/api/v1/assistant/machine/tools_test.rb
```

Expected: the retired stable errors and `command_allowlist` are absent from active Assistant policy code.

---

### Task 3: Prove unrestricted behavior through Assistant create, edit, save, and job-submission workflows

**Files:**
- Modify: `web/test/integration/api/v1/assistant/machine/control_center/templates_create_test.rb:3-216`
- Modify: `web/test/integration/api/v1/assistant/machine/control_center/templates_edit_test.rb:3-115`
- Modify: `web/test/integration/api/v1/assistant/machine/control_center/operations_test.rb:20-72`
- Modify: `web/test/services/assistant/confirmed_save_test.rb:24-85`
- Modify: `web/test/integration/api/v1/assistant/confirmed_saves_test.rb:13-25`
- Modify: `web/test/integration/assistant_end_to_end_test.rb:7-23`

**Interfaces:**
- Consumes: Task 1's unrestricted `TemplateValidator.call` and Task 2's `whiterabbit-v2` validation.
- Preserves: `create_whiterabbit_template`, `edit_whiterabbit_template`, `validate_whiterabbit_template`, and `submit_whiterabbit_job` routes, scopes, receipts, audit events, rate reservations, uniqueness, optimistic locking, and enqueue behavior.
- Produces: integration evidence that executable-name policy cannot reappear at a controller or confirmed-save boundary.

- [ ] **Step 1: Convert machine create coverage from allowlisted to unrestricted behavior**

Remove every `stub_methods(ControlCenter::TemplateValidator, allowlist: ...)` wrapper while retaining audit rollback, persistence failure, duplicate, scope, byte-budget, and gate tests.

Change the primary fixture command to `nuclei`, rename the happy-path test to `creates a valid cmdscript template with an unrestricted command`, and replace the current rejection test with:

```ruby
test "creates a shell command despite a stale retired allowlist and keeps it out of metadata audit" do
  original = ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"]
  ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"] = "httpx"
  body = VALID_TEMPLATE.deep_dup
  body[:name] = "assistant-shell-proof"
  body[:commands] = [ { command: "bash", args: [ "-c", "printf unrestricted" ], operator: "" } ]

  assert_difference -> { ControlCenter::Template.count }, 1 do
    post "/api/v1/assistant/machine/control_center/templates",
      params: { template: body }, headers: headers(write_grant), as: :json
  end

  assert_response :created
  record = ControlCenter::Template.find(response.parsed_body.dig("receipt", "target", "id"))
  assert_equal "bash", record.commands.first.fetch("command")
  audit = Assistant::AuditEvent.where(event: "machine.create").order(:id).last
  refute_includes audit.attributes.to_json, "printf unrestricted"
ensure
  ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"] = original
end
```

Add a structural negative using `command: "bad\nname"`; it must still return `validation_failed` and persist nothing.

- [ ] **Step 2: Split edit coverage into unrestricted success, stale conflict, and structural failure**

Remove all allowlist stubs. Keep the existing optimistic-lock success test, then replace the mixed stale/allowlist case with three single-purpose tests. The unrestricted case is:

```ruby
test "edits a template to an arbitrary command" do
  patch endpoint, params: {
    expected_lock_version: @template.lock_version,
    changes: { commands: [ { command: "python", args: [ "-c", "print('ok')" ] } ] }
  }, headers: headers(edit_grant), as: :json

  assert_response :success
  assert_equal "python", @template.reload.commands.first.fetch("command")
end
```

The stale test must change nothing and return `version_conflict`. The structural test must submit `command: "bad\nname"`, return `validation_failed`, and preserve the row. Do not use a once-disallowed but structurally valid command as a negative fixture.

- [ ] **Step 3: Make structured validation and job submission exercise the real unrestricted validator**

In `operations_test.rb`:

- validate a `nuclei` template without a validator stub;
- create a persisted template whose command is `bash` or `/opt/tools/custom-scanner`;
- submit it without stubbing `TemplateValidator.call`;
- keep `assert_enqueued_with(job: ControlCenter::SubmitJob)` so no binary is executed by the test; and
- retain receipt and human-attribution assertions.

Representative job setup:

```ruby
template = ControlCenter::Template.create!(
  name: "unrestricted-submit", kind: "cmdscript",
  commands: [ { "command" => "bash", "args" => [ "-c", "printf ok" ], "operator" => "" } ]
)
```

- [ ] **Step 4: Update confirmed-save tests to prove current revalidation ignores retired configuration**

Remove command-allowlist environment setup/teardown from all three confirmed-save/end-to-end files; retain `ASSISTANT_ANSIBLE_MODULE_ALLOWLIST` setup where Ansible tests require it.

Replace `revalidates against the current command policy before persistence` with:

```ruby
test "revalidates and persists an arbitrary command despite a stale retired allowlist" do
  attributes = TEMPLATE_ATTRIBUTES.deep_dup
  attributes["commands"] = [
    { "command" => "nuclei", "args" => [ "-tags", "crlf" ], "operator" => "" }
  ]
  draft = whiterabbit_draft(content: JSON.generate(attributes))
  original = ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"]
  ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"] = "httpx"

  result = Assistant::ConfirmedSave.call(draft: draft, user: @user, destination: nil)

  assert result.success?, result.errors.inspect
  assert_equal "nuclei", result.record.commands.first.fetch("command")
ensure
  ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"] = original
end
```

Ensure the helper uses `Assistant::DraftValidation::Whiterabbit::VALIDATION_VERSION`, so the new draft is reviewed under `whiterabbit-v2`. Retain the existing explicit stale-version test to prove old reviewed drafts are refused.

- [ ] **Step 5: Run the updated workflow coverage**

Run this after Tasks 1 and 2. These integration tests consume production behavior
already introduced under failing lower-level tests, so they may be green as soon
as their obsolete allowlist stubs and expectations are replaced:

```bash
PATH=/opt/rbenv/shims:/usr/local/go/bin:$PATH DB_HOST=172.17.0.1 DB_PORT=5433 DB_DATABASE_TEST=hunter_test bin/rails test test/integration/api/v1/assistant/machine/control_center/templates_create_test.rb test/integration/api/v1/assistant/machine/control_center/templates_edit_test.rb test/integration/api/v1/assistant/machine/control_center/operations_test.rb test/services/assistant/confirmed_save_test.rb test/integration/api/v1/assistant/confirmed_saves_test.rb test/integration/assistant_end_to_end_test.rb
```

Expected: all files pass; the job test enqueues but never executes a binary;
scope, gate, idempotency, audit, stale-version, and structural-validation
invariants remain green. Tasks 1 and 2 contain the RED-to-GREEN evidence for
the production changes; this task extends that evidence across the workflows.

- [ ] **Step 6: Review the task diff**

```bash
git diff --check -- web/test/integration/api/v1/assistant/machine/control_center/templates_create_test.rb web/test/integration/api/v1/assistant/machine/control_center/templates_edit_test.rb web/test/integration/api/v1/assistant/machine/control_center/operations_test.rb web/test/services/assistant/confirmed_save_test.rb web/test/integration/api/v1/assistant/confirmed_saves_test.rb web/test/integration/assistant_end_to_end_test.rb
git diff -- web/test/integration/api/v1/assistant/machine/control_center/templates_create_test.rb web/test/integration/api/v1/assistant/machine/control_center/templates_edit_test.rb web/test/integration/api/v1/assistant/machine/control_center/operations_test.rb web/test/services/assistant/confirmed_save_test.rb web/test/integration/api/v1/assistant/confirmed_saves_test.rb web/test/integration/assistant_end_to_end_test.rb
```

Expected: no allowlist stubs or allowlist-negative assertions remain; structural and authorization negatives remain.

---

### Task 4: Remove the retired activation and deployment configuration

**Files:**
- Modify: `web/test/services/assistant/config_test.rb:77-138`
- Modify: `web/test/config/assistant_compose_test.rb`
- Modify: `web/test/javascript/assistant_controller_test.mjs:453-477`
- Modify: `web/app/services/assistant/config.rb:107-111`
- Modify: `web/app/javascript/lib/assistant_ui.js:41-49`
- Modify: `.env.example:85-90`
- Modify: `.env` (remove only `HUNTER_CONTROL_CENTER_COMMAND_ALLOWLIST`; preserve every unrelated value and secret)
- Modify: `docker-compose.yaml:125-137`
- Modify: `docker-compose.prod.yaml:102-114`
- Modify: `docs/runbooks/hunter-assistant-first-boot.md:51-70,168-178`

**Interfaces:**
- Consumes: ordinary environment lookup through `Assistant::Config.configured`.
- Produces: `Assistant::Config.configuration_reasons` requiring only `ADMIN_USERNAME` and `ASSISTANT_ANSIBLE_MODULE_ALLOWLIST` among content-policy settings.
- Produces: Compose `web.environment` with no `CONTROL_CENTER_COMMAND_ALLOWLIST` key and `.env.example` with no `HUNTER_CONTROL_CENTER_COMMAND_ALLOWLIST` input.

- [ ] **Step 1: Write failing activation tests**

Update the missing/complete/retention cases so command policy is not part of configuration:

```ruby
test "missing configuration yields active reason codes instead of raising" do
  stub_methods(Assistant::Config, configured: ->(_key) { nil }) do
    reasons = Assistant::Config.configuration_reasons

    assert_includes reasons, "missing_admin_username"
    assert_includes reasons, "missing_ansible_module_allowlist"
    refute_includes reasons, "missing_command_allowlist"
  end
end

test "configuration is complete without a Whiterabbit command setting" do
  values = {
    "ADMIN_USERNAME" => "admin",
    "ASSISTANT_ANSIBLE_MODULE_ALLOWLIST" => "ansible.builtin.uri"
  }

  stub_methods(Assistant::Config, configured: ->(key) { values[key] }) do
    assert_empty Assistant::Config.configuration_reasons
  end
end
```

Remove `CONTROL_CENTER_COMMAND_ALLOWLIST` from the retention fixture and correct the “three required settings” comment to “required settings.”

- [ ] **Step 2: Add failing parsed-Compose and example-environment assertions**

Add this contract test to `assistant_compose_test.rb`:

```ruby
def test_whiterabbit_command_allowlist_is_absent_from_active_deployment_configuration
  each_compose do |filename, config|
    environment = config.fetch("services").fetch("web").fetch("environment")
    refute environment.key?("CONTROL_CENTER_COMMAND_ALLOWLIST"),
      "#{filename}: web still receives the retired command allowlist"
  end

  refute_includes ROOT.join(".env.example").read, "HUNTER_CONTROL_CENTER_COMMAND_ALLOWLIST"
end
```

- [ ] **Step 3: Add a failing client reason-map assertion**

Extend the existing disabled-copy test:

```javascript
assert.equal(ui.DISABLED_COPY.missing_command_allowlist, undefined)
```

- [ ] **Step 4: Run focused tests and verify RED**

From `web/`:

```bash
PATH=/opt/rbenv/shims:/usr/local/go/bin:$PATH DB_HOST=172.17.0.1 DB_PORT=5433 DB_DATABASE_TEST=hunter_test bin/rails test test/services/assistant/config_test.rb test/config/assistant_compose_test.rb
node --test test/javascript/assistant_controller_test.mjs
```

Expected: Rails still reports `missing_command_allowlist`; both Compose files and `.env.example` still contain the setting; JavaScript still exposes the retired reason.

- [ ] **Step 5: Remove the activation reason and browser-copy entry**

Set the active required settings to:

```ruby
REQUIRED_SETTINGS = {
  "ADMIN_USERNAME" => "missing_admin_username",
  "ASSISTANT_ANSIBLE_MODULE_ALLOWLIST" => "missing_ansible_module_allowlist"
}.freeze
```

Delete `missing_command_allowlist` from `DISABLED_COPY` without adding a replacement.

- [ ] **Step 6: Remove the deployment variable everywhere active**

Using `apply_patch`, remove only these mappings/lines:

```text
CONTROL_CENTER_COMMAND_ALLOWLIST: ${HUNTER_CONTROL_CENTER_COMMAND_ALLOWLIST:-}
HUNTER_CONTROL_CENTER_COMMAND_ALLOWLIST=curl,httpx
```

Delete the associated `.env.example` allowlist warning. In the ignored local `.env`, remove only the `HUNTER_CONTROL_CENTER_COMMAND_ALLOWLIST=...` line; do not print, rewrite, reorder, or otherwise expose the file.

- [ ] **Step 7: Correct the active first-boot runbook**

Replace the two-gate section with:

````markdown
The Assistant's remaining content-policy activation gate is the Ansible module
allowlist. Keep it at the narrowest value your playbooks require:

```text
HUNTER_ASSISTANT_ANSIBLE_MODULE_ALLOWLIST=ansible.builtin.debug
```

Whiterabbit executable names are intentionally unrestricted. Template and job
authorization is enforced by Hunter's dedicated tool/scopes and live gates, not
by deployment command configuration.
````

In Step 4, remove `missing_command_allowlist` and leave only the Ansible reason pointing to “Before you start.” Do not rewrite historical specs or plans.

- [ ] **Step 8: Run focused tests and verify GREEN**

Run the Step 4 commands again.

Expected: Rails, parsed Compose/example configuration, and JavaScript tests pass.

- [ ] **Step 9: Prove a stale external variable has no active references**

From the repository root:

```bash
rg -n 'CONTROL_CENTER_COMMAND_ALLOWLIST|missing_command_allowlist' web/app web/test .env.example docker-compose.yaml docker-compose.prod.yaml docs/runbooks AGENTS.md
```

Expected: no matches. Matches in historical `docs/superpowers/plans/` or superseded specs are intentionally excluded from this active-source check.

---

### Task 5: Disclose and govern the unrestricted Whiterabbit exception

**Files:**
- Modify: `web/test/integration/assistant_shell_test.rb:74-82`
- Modify: `web/test/integration/settings/assistant_test.rb:14-57`
- Modify: `web/test/config/assistant_release_gate_test.rb:73-112`
- Modify: `web/app/views/layouts/_assistant.html.erb:50-74`
- Modify: `web/app/views/settings/_assistant.html.erb:1-17,129-131`
- Modify: `AGENTS.md:119-201`
- Modify: `docs/security/hunter-assistant-production-checklist.md:10-17,65-89`

**Interfaces:**
- Consumes: the approved threat-model delta and existing Assistant capability gates.
- Produces: rendered disclosure that distinguishes Hunter API record deletion/secret tools from arbitrary Whiterabbit worker effects.
- Produces: a project-context approved exception and a candidate-specific production evidence row.

- [ ] **Step 1: Write failing disclosure assertions**

Update `assistant_shell_test.rb` to require the actual runtime consequence:

```ruby
assert_select "#hunter-assistant-capability-disclosure", text: /Whiterabbit templates with any executable/i
assert_select "#hunter-assistant-capability-disclosure", text: /network, filesystem, process, privilege, or destructive effects/i
assert_select "#hunter-assistant-capability-disclosure", text: /no dedicated Hunter secret-value or record-delete tool/i
```

Update `settings/assistant_test.rb` to require:

```ruby
assert_includes response.body, "any executable"
assert_includes response.body, "destructive effects"
assert_includes response.body, "Whiterabbit worker"
assert_includes response.body, "no dedicated secret-value or record-delete tool"
```

Replace the previous absolute `never see secrets`/`delete records` assertions, which are misleading once a worker command can attempt arbitrary runtime access.

- [ ] **Step 2: Add failing release-context assertions**

Extend `assistant_release_gate_test.rb`:

```ruby
assert_includes agents, "Unrestricted Whiterabbit command authoring and execution"
assert_includes checklist, "Unrestricted Whiterabbit command authoring and execution"
assert_includes checklist, "arbitrary worker execution"
```

This guards the approved exception and production gate as source contracts; it does not test prose wording beyond the named boundary.

- [ ] **Step 3: Run disclosure/release tests and verify RED**

```bash
PATH=/opt/rbenv/shims:/usr/local/go/bin:$PATH DB_HOST=172.17.0.1 DB_PORT=5433 DB_DATABASE_TEST=hunter_test bin/rails test test/integration/assistant_shell_test.rb test/integration/settings/assistant_test.rb test/config/assistant_release_gate_test.rb
```

Expected: rendered pages and governance documents lack the new unrestricted-execution disclosure.

- [ ] **Step 4: Update the compact chat header and full disclosure**

Use compact header copy such as:

```erb
<p class="truncate text-[11px] text-zinc-500 dark:text-zinc-500">Broad Hunter operations through MCP · unrestricted Whiterabbit jobs</p>
```

The full disclosure must state, as one cohesive paragraph:

```text
The assistant has administrator-equivalent operational access through the reviewed Hunter MCP catalog. It can create and edit Whiterabbit templates with any executable and submit them without another prompt. Those jobs can cause arbitrary network, filesystem, process, privilege, or destructive effects available to the Whiterabbit worker; you are responsible for target authorization and requested effects. Hunter attributes and metadata-audits these actions, applies exact tools/scopes, budgets, and live gates, and provides no dedicated Hunter secret-value or record-delete tool. The assistant still cannot administer users, tokens, providers, Assistant security settings, or bypass Hunter MCP with a generic proxy.
```

Retain the direct-conversation organization sentence after this paragraph.

- [ ] **Step 5: Update settings disclosure**

Apply the same facts at settings-page altitude: unrestricted executable names, no second prompt for requested job submission, arbitrary worker runtime effects, administrator responsibility, metadata audit, immediate live gates, and no dedicated Hunter secret-value or record-delete API tool. Keep the existing backend/login/retention sections and control inputs unchanged.

- [ ] **Step 6: Record the narrow approved exception in `AGENTS.md`**

Append a third bullet under “Approved exceptions” with this exact scope:

```markdown
- **Unrestricted Whiterabbit command authoring and execution** (approved delta:
  `docs/superpowers/specs/2026-08-23-unrestricted-whiterabbit-command-authoring-design.md`).
  The configured Assistant administrator may use any structurally valid
  executable name and arguments in templates created or edited through the
  dedicated Whiterabbit tools, and may submit those templates through the
  separately authorized job tool when their message requests it, conditioned
  on all of the following remaining true:
  - Validation still enforces closed schemas, bounds, operators, NUL/newline
    rejection, and Assistant secret-input detection; it performs no executable
    classification or allowlisting.
  - Template validation, create, edit, target resolution, and job submission
    remain separately named MCP tools with exact non-wildcard scopes, live
    human-controlled gates, budgets, idempotency, human attribution, action
    receipts, and metadata-only audit.
  - Selecting a shell, interpreter, privilege/container/file utility, custom
    binary, or future binary is explicitly permitted. The operator accepts that
    submitted jobs can cause arbitrary network, filesystem, process, privilege,
    destructive, or exfiltration effects available to the Whiterabbit worker.
  - This exception adds no generic MCP shell/network/filesystem/request/execution
    tool, no secret-value API, no Hunter record-destroy API, no governance tool,
    and no direct worker identity or callback access.
  - Production activation remains gated by candidate-specific evidence in
    `docs/security/hunter-assistant-production-checklist.md` and an independent
    review explicitly acknowledging arbitrary worker execution.

  Any wider direct execution path, removal of the remaining schema,
  authorization, revocation, budget, idempotency, attribution, disclosure,
  audit, or production gates, or expansion beyond the Whiterabbit workflow,
  requires another approved threat-model delta.
```

- [ ] **Step 7: Amend the production checklist without claiming evidence exists**

Add the new design to the active-design paragraph. In the existing administrator-proxy row, replace “validators reject disallowed command/module” with “validators reject structurally invalid command content, disallowed Ansible modules, and secret fixtures.” Add a separate row named `Unrestricted Whiterabbit command authoring and execution` requiring:

- arbitrary-command browser/Assistant validation, create, edit, and submission evidence;
- exact catalog parity proving no generic tool was introduced;
- live Codex and Claude runs using an active scanner and another formerly unlisted installed binary;
- immediate write/submit gate revocation, idempotent receipts, attribution, and metadata-only audit;
- worker identity/capabilities/mount/environment-name/network/binary inventory review;
- command/job/secret canary checks; and
- independent acceptance of destruction/exfiltration residual risk.

Leave the row's evidence/result fields as `UNSET` and `Not run`; implementation is not production approval.

- [ ] **Step 8: Run disclosure/release tests and verify GREEN**

Run the Step 3 command again.

Expected: all rendered disclosure and release-context tests pass.

- [ ] **Step 9: Review the task diff for accidental relaxation**

```bash
git diff --check -- web/app/views/layouts/_assistant.html.erb web/app/views/settings/_assistant.html.erb web/test/integration/assistant_shell_test.rb web/test/integration/settings/assistant_test.rb web/test/config/assistant_release_gate_test.rb AGENTS.md docs/security/hunter-assistant-production-checklist.md
git diff -- web/app/views/layouts/_assistant.html.erb web/app/views/settings/_assistant.html.erb AGENTS.md docs/security/hunter-assistant-production-checklist.md
```

Expected: the exception is limited to existing Whiterabbit template/job tools; no unrelated secret, delete, governance, generic MCP, Ansible, audit, or production gate is weakened.

---

### Task 6: Run focused, full, parity, and static verification

**Files:**
- Verify: all files modified in Tasks 1-5
- Verify: `docs/superpowers/specs/2026-08-23-unrestricted-whiterabbit-command-authoring-design.md`
- Verify: `docs/superpowers/plans/2026-08-23-unrestricted-whiterabbit-command-authoring.md`

**Interfaces:**
- Consumes: the complete implementation and approved delta.
- Produces: local verification evidence only; it does not populate production evidence or enable the Assistant.

- [ ] **Step 1: Confirm active allowlist references are gone**

```bash
rg -n 'CONTROL_CENTER_COMMAND_ALLOWLIST|command_allowlist|missing_command_allowlist|assistant_command_policy_unconfigured|assistant_command_not_allowed' web/app web/test .env.example docker-compose.yaml docker-compose.prod.yaml docs/runbooks AGENTS.md
```

Expected: no matches. The approved new design and historical `docs/superpowers` records are intentionally outside this active-source scan.

- [ ] **Step 2: Run all focused Rails tests together**

From `web/`:

```bash
PATH=/opt/rbenv/shims:/usr/local/go/bin:$PATH DB_HOST=172.17.0.1 DB_PORT=5433 DB_DATABASE_TEST=hunter_test bin/rails test test/services/control_center/template_validator_test.rb test/integration/api/v1/control_center/templates_yaml_test.rb test/services/assistant/draft_validation/whiterabbit_test.rb test/services/assistant/authoring_policy_test.rb test/services/assistant/config_test.rb test/services/assistant/confirmed_save_test.rb test/integration/api/v1/assistant/confirmed_saves_test.rb test/integration/api/v1/assistant/machine/tools_test.rb test/integration/api/v1/assistant/machine/control_center/templates_create_test.rb test/integration/api/v1/assistant/machine/control_center/templates_edit_test.rb test/integration/api/v1/assistant/machine/control_center/operations_test.rb test/integration/assistant_end_to_end_test.rb test/integration/assistant_shell_test.rb test/integration/settings/assistant_test.rb test/config/assistant_compose_test.rb test/config/assistant_release_gate_test.rb
```

Expected: zero failures and zero errors.

- [ ] **Step 3: Run the full Rails suite**

```bash
PATH=/opt/rbenv/shims:/usr/local/go/bin:$PATH DB_HOST=172.17.0.1 DB_PORT=5433 DB_DATABASE_TEST=hunter_test bin/rails test
```

Expected: zero failures and zero errors. Record the run/assertion counts in the handoff.

- [ ] **Step 4: Run all JavaScript tests**

From `web/`:

```bash
node --test test/javascript/*.mjs
```

Expected: zero failures.

- [ ] **Step 5: Run Rails loading, capability coverage, CSS, and static analysis**

From `web/`, run each command separately:

```bash
PATH=/opt/rbenv/shims:/usr/local/go/bin:$PATH DB_HOST=172.17.0.1 DB_PORT=5433 DB_DATABASE_TEST=hunter_test bin/rails zeitwerk:check
```

```bash
PATH=/opt/rbenv/shims:/usr/local/go/bin:$PATH DB_HOST=172.17.0.1 DB_PORT=5433 DB_DATABASE_TEST=hunter_test bin/rails assistant:capabilities:verify
```

```bash
PATH=/opt/rbenv/shims:/usr/local/go/bin:$PATH bin/rails tailwindcss:build
```

```bash
PATH=/opt/rbenv/shims:/usr/local/go/bin:$PATH bundle exec brakeman --no-pager -w3 --exit-on-warn --exit-on-error
```

Expected: Zeitwerk succeeds; the capability task reports the same reviewed operation/tool counts; Tailwind builds; Brakeman reports no high-confidence warning/error.

- [ ] **Step 6: Run all Assistant Go race suites even though catalog code is unchanged**

Run from each module directory so provider/catalog parity cannot regress unnoticed:

```bash
go test -race ./...
```

Directories:

- `assistant/codex`
- `assistant/claude`
- `assistant/gateway`
- `assistant/mcp`
- `assistant/validator`

Expected: all five modules pass.

- [ ] **Step 7: Inspect the complete diff and workspace state**

```bash
git diff --check
git status --short
git diff --stat
git diff
```

Expected: only scoped implementation, test, configuration, disclosure, project-context, checklist, approved spec, and plan changes appear; `.vscode/` remains untouched; no secret value appears in diff; no commit exists unless the user separately requested one.

- [ ] **Step 8: Report local completion without claiming production approval**

The handoff must include:

- the two fixed user-visible paths;
- the `whiterabbit-v2` policy/version consequence for old drafts;
- focused/full Rails, JavaScript, Zeitwerk, capability, Tailwind, Brakeman, and Go results;
- any unavailable verification with its exact reason;
- confirmation that production checklist evidence is still `UNSET`/`Not run` and `ASSISTANT_ENABLED` was not changed; and
- confirmation that no commit was created unless separately authorized.
