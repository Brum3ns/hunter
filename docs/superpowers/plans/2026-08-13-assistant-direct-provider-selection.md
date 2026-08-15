# Assistant Direct Provider Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace token-backed provider-profile selection with one-click OpenAI/Codex and Anthropic/Claude Code conversations, backed by isolated subscription-authenticated CLI services.

**Architecture:** A closed Rails backend resolver maps `codex` and `claude_code` to synthetic profile rows while preserving existing foreign keys and legacy transcript provenance. Direct turns share grant issuance and event ingestion but dispatch through provider-specific clients; a new hardened Go service wraps the pinned Codex CLI using JSONL/resume contracts and the exact reviewed Hunter MCP catalog.

**Tech Stack:** Ruby 3.3.6, Rails 8, PostgreSQL, Stimulus/importmap, Go 1.25.12, official Codex CLI 0.144.4 (pin verified 2026-08-13), official Claude Code CLI, MCP, Docker Compose, Minitest, Go testing, Node test runner.

## Global Constraints

- Browser/API backend schema is exactly `codex | claude_code`; no profile ID, model, URL, command, flag, or wildcard input.
- Provider API keys and legacy provider availability never activate, select, create, or continue a chat.
- Legacy transcripts stay readable/manageable but new turns return `409 legacy_provider_retired` before grant/job creation.
- Codex uses ChatGPT login only; no `OPENAI_API_KEY`, `CODEX_API_KEY`, or API-key login path.
- Codex 0.144.4 model-visible built-ins equal exactly `list_mcp_resources`, `list_mcp_resource_templates`, `read_mcp_resource`, `update_plan`, `request_user_input`, `apply_patch`, `view_image`, and `tool_search`; any ninth or changed built-in blocks the pin.
- Every Hunter read/effect, including a future API-backed feature, traverses the sole authenticated `hunter` MCP source, whose deferred catalog equals the current `Assistant::Grants::Issuer::CHAT_TOOLS` catalog after the Control Center write toggle narrows it.
- Shell/unified execution, web/browser/computer use, apps/plugins/skills, image generation, permission request, and multi-agent tools remain absent; `apply_patch` is non-effectful under the read-only sandbox and immutable empty workspace, proven by a real-binary adversarial test.
- Runner failures are one-shot, namespaced stable codes and never include raw CLI output, prompt/reply bodies, credentials, tool arguments, session/thread IDs, or argv.
- Codex and Claude credentials, ingress tokens, volumes, and internal networks remain isolated and independently revocable.
- Production remains disabled until the Assistant production checklist records the new evidence.

---

### Task 1: Closed direct-backend domain and persistence

**Files:**
- Create: `web/app/services/assistant/chat_backend.rb`
- Create: `web/test/services/assistant/chat_backend_test.rb`
- Create: `web/db/migrate/20260813010000_add_codex_thread_id_to_assistant_conversations.rb`
- Modify: `web/db/schema.rb`
- Modify: `web/config/assistant_provider_catalog.yml`
- Modify: `web/app/models/assistant/provider_profile.rb`
- Modify: `web/app/models/assistant/conversation.rb`
- Modify: `web/test/fixtures/assistant_provider_profiles.yml`
- Modify: `web/test/fixtures/assistant_conversations.yml`
- Modify: `web/test/models/assistant/provider_profile_test.rb`
- Modify: `web/test/models/assistant/conversation_test.rb`

**Interfaces:**
- Produces: `Assistant::ChatBackend::SLUGS = %w[codex claude_code]`
- Produces: `Assistant::ChatBackend.fetch(slug): Assistant::ProviderProfile | nil`
- Produces: `Assistant::ChatBackend.slug_for(profile): String | nil`
- Produces: `Assistant::ChatBackend.descriptors: Array<Hash>`
- Produces: `ProviderProfile#codex?`, `#direct_chat?`, `#chat_backend_slug`

- [ ] **Step 1: Write failing closed-domain tests**

```ruby
test "fetch resolves only the two enabled reviewed synthetic rows" do
  assert_equal assistant_provider_profiles(:codex), Assistant::ChatBackend.fetch("codex")
  assert_equal assistant_provider_profiles(:claude_code), Assistant::ChatBackend.fetch("claude_code")
  assert_nil Assistant::ChatBackend.fetch("openai_primary")
  assert_nil Assistant::ChatBackend.fetch("../codex")
end

test "descriptors expose no profile secret or arbitrary model contract" do
  payload = Assistant::ChatBackend.descriptors
  assert_equal %w[codex claude_code], payload.map { |item| item.fetch(:slug) }.sort
  refute_match(/secret_ref|api_key|provider_profile_id/, payload.to_json)
end
```

Add model tests that a Codex conversation rejects `claude_session_id`, a Claude
conversation rejects `codex_thread_id`, and provider bindings remain immutable.

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
cd web
bin/rails test test/services/assistant/chat_backend_test.rb test/models/assistant/provider_profile_test.rb test/models/assistant/conversation_test.rb
```

Expected: FAIL because the resolver, Codex catalog row, and column are absent.

- [ ] **Step 3: Add the migration and catalog/profile helpers**

The migration adds only nullable `codex_thread_id :string`. Add catalog entry:

```yaml
codex:
  provider: codex
  model: codex
  secret_ref: codex
  secret_env: ""
  input_limit: 32768
  output_limit: 8192
  retention_posture: standard
```

Implement direct helpers from `catalog_slug`; do not infer from mutable name or
provider text.

- [ ] **Step 4: Implement the resolver and session-binding validation**

```ruby
module Assistant::ChatBackend
  SLUGS = %w[codex claude_code].freeze
  BRANDS = { "codex" => "openai", "claude_code" => "anthropic" }.freeze

  def self.fetch(slug)
    value = slug.to_s
    return unless SLUGS.include?(value)
    Assistant::ProviderProfile.find_by(catalog_slug: value)
  end

  def self.slug_for(profile)
    profile&.catalog_slug if SLUGS.include?(profile&.catalog_slug)
  end
end
```

Descriptors contain only `slug`, `brand`, `name`, `enabled`,
`retention_posture`, and `reviewed_at`.

- [ ] **Step 5: Migrate and verify GREEN**

Run:

```bash
cd web
bin/rails db:migrate
bin/rails test test/services/assistant/chat_backend_test.rb test/models/assistant/provider_profile_test.rb test/models/assistant/conversation_test.rb
```

Expected: migration and tests pass.

- [ ] **Step 6: Commit**

```bash
git add web/db web/config/assistant_provider_catalog.yml web/app/services/assistant/chat_backend.rb web/app/models/assistant web/test/services/assistant/chat_backend_test.rb web/test/models/assistant web/test/fixtures
git commit -m "Add the closed direct Assistant backend domain"
```

### Task 2: Closed conversation API, activation, and legacy retirement

**Files:**
- Modify: `web/app/controllers/api/v1/assistant/conversations_controller.rb`
- Modify: `web/app/controllers/api/v1/assistant/bootstrap_controller.rb`
- Modify: `web/app/controllers/api/v1/assistant/base_controller.rb`
- Modify: `web/app/controllers/api/v1/assistant/turns_controller.rb`
- Modify: `web/app/services/assistant/activation.rb`
- Modify: `web/app/services/assistant/turn_creator.rb`
- Modify: `web/db/seeds.rb`
- Modify: `web/test/integration/api/v1/assistant/conversations_test.rb`
- Modify: `web/test/integration/api/v1/assistant/turns_test.rb`
- Modify: `web/test/services/assistant/activation_test.rb`
- Modify: `web/test/services/assistant/turn_creator_test.rb`
- Modify: `web/test/integration/api/v1/assistant/openapi_test.rb`

**Interfaces:**
- Consumes: `ChatBackend.fetch(params[:backend])`
- Produces: exact create body `{ backend: String }`
- Produces: bootstrap key `chat_backends`
- Produces: conversation fields `backend`, `brand`, `legacy`
- Produces: rejection code `legacy_provider_retired` with HTTP 409

- [ ] **Step 1: Replace old API expectations with failing closed-schema tests**

```ruby
test "one backend slug creates a pinned direct conversation" do
  post "/api/v1/assistant/conversations", params: { backend: "codex" }, as: :json
  assert_response :created
  assert_equal "codex", response.parsed_body.fetch("backend")
  assert_equal "openai", response.parsed_body.fetch("brand")
end

test "profile ids unknown keys and legacy slugs cannot create conversations" do
  [
    { provider_profile_id: assistant_provider_profiles(:openai).id },
    { backend: "openai_primary" },
    { backend: "codex", model: "anything" }
  ].each do |body|
    assert_no_difference(-> { Assistant::Conversation.count }) do
      post "/api/v1/assistant/conversations", params: body, as: :json
    end
    assert_includes [400, 404], response.status
  end
end
```

Add a turn test proving `legacy_provider_retired`, HTTP 409, zero changes to
turn/message/grant/audit counts, and no enqueue.

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
cd web
bin/rails test test/integration/api/v1/assistant/conversations_test.rb test/integration/api/v1/assistant/turns_test.rb test/services/assistant/activation_test.rb test/services/assistant/turn_creator_test.rb
```

Expected: FAIL on the old `provider_profile_id` path and credential activation.

- [ ] **Step 3: Close conversation creation and serialization**

Use `exact_request_body!(%w[backend])`, resolve the backend, return `404` when
the slug/profile is absent, and pass only the resolved record to
`Conversation.start!`. Bootstrap serializes `chat_backends` and no longer sends
arbitrary provider profiles. Conversation serialization derives backend/brand
from the immutable profile and sets `legacy: backend.nil?`.

- [ ] **Step 4: Retire legacy turns before authority creation**

In the locked `TurnCreator` transaction, derive the backend and raise
`Rejected, "legacy_provider_retired"` before rate consumption, message append,
grant issuance, or audit. Direct backends share `CHAT_TOOLS`; no direct path
resolves browser context references. Map the code to `:conflict` in
`TurnsController#render_rejected`.

- [ ] **Step 5: Make activation provider-key independent**

Keep the environment kill override and configuration-reason checks. When they
pass, activation is active with `available_slugs: ChatBackend::SLUGS`; never
consult `ProviderCredentials`. The database administrator kill switch remains
part of `effective_enabled` and turn verification.

- [ ] **Step 6: Seed both synthetic rows idempotently**

Loop over exact values `{ "codex" => "Codex", "claude_code" => "Claude Code" }`,
using `find_or_create_by!` and never re-enabling an existing disabled row.

- [ ] **Step 7: Run tests and verify GREEN**

Run the focused command from Step 2 plus OpenAPI integration tests. Expected:
all pass; responses contain no `secret_ref`, provider key status, or session ID.

- [ ] **Step 8: Commit**

```bash
git add web/app/controllers/api/v1/assistant web/app/services/assistant/activation.rb web/app/services/assistant/turn_creator.rb web/db/seeds.rb web/test
git commit -m "Retire token-backed Assistant chat selection"
```

### Task 3: Backend-neutral turn dispatch and Rails Codex client

**Files:**
- Create: `web/app/services/assistant/codex_client.rb`
- Create: `web/test/services/assistant/codex_client_test.rb`
- Create: `web/test/services/assistant/codex_dispatch_test.rb`
- Modify: `web/app/jobs/assistant/turn_job.rb`
- Modify: `web/app/services/assistant/turn_creator.rb`
- Modify: `web/app/services/assistant/claude_code_client.rb`
- Modify: `web/test/jobs/assistant/turn_job_test.rb`
- Modify: `web/test/services/assistant/claude_code_dispatch_test.rb`

**Interfaces:**
- Produces: `CodexClient.run_turn(turn:, prompt:, turn_grant:, poster:): Array<Hash>`
- Produces: `CodexClient.endpoint: String`
- Produces: `ClaudeCodeClient.endpoint: String`
- Produces: job args `backend: "codex" | "claude_code"`

- [ ] **Step 1: Write failing Codex client tests**

Mirror the complete Claude client contract but assert Codex-specific behavior:

```ruby
test "success stores the thread id and returns the shared event contract" do
  poster = ->(body) { { "thread_id" => "thr_9", "reply" => "Hi" } }
  events = Assistant::CodexClient.run_turn(turn: @turn, prompt: "hello", poster: poster)
  assert_equal %w[assistant_message completed], events.map { |event| event["kind"] }
  assert_equal "thr_9", @turn.conversation.reload.codex_thread_id
end

test "resume and grant are sent only from persisted server state" do
  @turn.conversation.update!(codex_thread_id: "thr_old")
  seen = nil
  Assistant::CodexClient.run_turn(turn: @turn, prompt: "again", turn_grant: "raw", poster: ->(body) {
    seen = body
    { "thread_id" => "thr_old", "reply" => "ok" }
  })
  assert_equal({ "prompt" => "again", "thread_id" => "thr_old", "turn_grant" => "raw" }, seen)
end
```

Cover every stable timeout/DNS/refused/unreachable/malformed/not-configured/error
mapping and assert unknown service codes collapse to `codex_error`.

- [ ] **Step 2: Run tests and verify RED**

Run: `cd web && bin/rails test test/services/assistant/codex_client_test.rb test/services/assistant/codex_dispatch_test.rb test/jobs/assistant/turn_job_test.rb`

Expected: FAIL because `CodexClient` and backend job routing do not exist.

- [ ] **Step 3: Implement CodexClient from the proven Claude boundary**

Use `ASSISTANT_CODEX_URL`, `ASSISTANT_CODEX_INGRESS_TOKEN`, `/chat`, the same
bounded Net::HTTP timeouts, and the existing event envelope. Whitelist service
error codes with a frozen set; never forward an arbitrary string.

- [ ] **Step 4: Replace the boolean job switch with a closed backend switch**

```ruby
case backend
when "codex"
  Assistant::CodexClient.run_turn(turn: turn, prompt: prompt, turn_grant: turn_grant)
when "claude_code"
  Assistant::ClaudeCodeClient.run_turn(turn: turn, prompt: prompt, turn_grant: turn_grant)
when nil
  Assistant::GatewayClient.run_turn(envelope)
else
  [error_event(turn, "assistant_backend_invalid")]
end
```

Only `TurnCreator` constructs this job argument. Direct empty responses use
`#{backend.sub('_code', '')}_returned_no_events` through an explicit map, not
string interpolation from request data.

- [ ] **Step 5: Verify both direct dispatches and legacy inaccessibility**

Run all files listed above plus `turn_creator_test.rb`. Expected: each direct
backend is called exactly once, raw grants are cleared after enqueue, and the
gateway is never called for a direct or rejected legacy turn.

- [ ] **Step 6: Commit**

```bash
git add web/app/services/assistant/codex_client.rb web/app/services/assistant/claude_code_client.rb web/app/services/assistant/turn_creator.rb web/app/jobs/assistant/turn_job.rb web/test/services/assistant web/test/jobs/assistant/turn_job_test.rb
git commit -m "Dispatch Assistant turns through direct CLI backends"
```

### Task 4: Hardened Codex wrapper

**Files:**
- Create: `assistant/codex/go.mod`
- Create: `assistant/codex/internal/chat/chat.go`
- Create: `assistant/codex/internal/chat/chat_test.go`
- Create: `assistant/codex/cmd/hunter-assistant-codex/main.go`
- Create: `assistant/codex/cmd/hunter-assistant-codex/main_test.go`
- Create: `assistant/codex/Dockerfile`

**Interfaces:**
- HTTP `POST /chat`: `{prompt, thread_id?, turn_grant?}` → `{thread_id, reply}`
- HTTP `GET /healthz` → 204
- Produces stable closed errors consumed by `Assistant::CodexClient`.

- [ ] **Step 1: Write failing argv and JSONL parser tests**

Table-drive literal expectations for new and resumed turns. The invocation must
contain `exec`, `--json`, `--color never`, `--skip-git-repo-check`,
`--ignore-user-config`, `--ignore-rules`, and explicit disable/config arguments;
resume must be `exec resume <thread_id>`. Assert prompt is one argv element,
credentials/grants are absent from argv, and malformed/oversized/multiple final
messages fail closed.

- [ ] **Step 2: Run Go tests and verify RED**

Run: `cd assistant/codex && go test ./...`

Expected: FAIL because the module and implementation do not exist.

- [ ] **Step 3: Implement the CLI boundary**

Use `exec.CommandContext` with an explicit minimal environment. Disable at least:
`shell_tool`, `unified_exec`, `browser_use`, `browser_use_external`,
`browser_use_full_cdp_access`, `computer_use`, `apps`, `plugins`,
`image_generation`, `multi_agent`, and `request_permissions_tool`; set
`web_search="disabled"`, `approval_policy="never"`, and `sandbox_mode="read-only"`.
Force `forced_login_method="chatgpt"` in the service-owned config.

Parse only JSON objects with known event types. Capture the first
`thread.started.thread_id`, the completed `item.agent_message.text`, and a
terminal `turn.completed`; map `turn.failed` error categories to the closed
codes. Bound request, line, total output, timeout, and reply sizes.

- [ ] **Step 4: Write failing HTTP boundary tests**

Exercise method → Host → bearer → bounded body ordering, constant-time bearer
comparison, missing prompt, cross-field types, fake Codex success/login/error,
and assert raw stdout/stderr/auth/grant never appears in responses.

- [ ] **Step 5: Implement `/chat` and `/healthz`**

Follow the existing Claude wrapper's server hardening, but use port `8084`,
`ASSISTANT_CODEX_*` names, and exact JSON structs with unknown fields rejected.
One request spawns at most one Codex process; canceled HTTP context kills it.

- [ ] **Step 6: Add the pinned runtime image**

Use a Go build stage and `node:22-slim` runtime with
`npm install -g @openai/codex@0.144.4`. Reuse uid/gid 1000, set
`CODEX_HOME=/home/codex/.codex`, create immutable `/workspace`, expose 8084, and
mount no source code in the image.

- [ ] **Step 7: Run all Go tests and image smoke**

Run:

```bash
cd assistant/codex && go test ./...
cd ../.. && docker build -t hunter-assistant-codex -f assistant/codex/Dockerfile assistant/codex
docker run --rm --entrypoint codex hunter-assistant-codex --version
```

Expected: tests pass and version is exactly `codex-cli 0.144.4`.

- [ ] **Step 8: Commit**

```bash
git add assistant/codex
git commit -m "Add the hardened Codex Assistant service"
```

### Task 5: Real Codex tool-schema gate and Compose isolation

**Files:**
- Create: `assistant/codex/internal/chat/tool_schema_contract_test.go`
- Create: `ops/assistant/seccomp/codex.json`
- Modify: `docker-compose.yaml`
- Modify: `docker-compose.prod.yaml`
- Modify: `.env.example`
- Modify: `web/test/config/assistant_compose_test.rb`
- Modify: `web/app/services/assistant/preflight.rb`
- Modify: `web/test/services/assistant/preflight_test.rb`
- Modify: `docs/superpowers/specs/2026-08-13-assistant-direct-provider-selection-design.md`
- Create: `docs/superpowers/specs/2026-08-15-assistant-codex-mcp-boundary-design.md`

**Interfaces:**
- New service: `assistant-codex:8084`
- Rails env: `ASSISTANT_CODEX_URL`, `ASSISTANT_CODEX_INGRESS_TOKEN`
- Codex env: exact Host/MCP/provider settings; no provider API key.

- [ ] **Step 1: Add failing Compose contract tests**

Extend exact service/network/mount maps for `assistant-codex`; assert only
`assistant_codex_home:/home/codex/.codex` is persistent, no host bind exists,
no API-key variable is present, no port is published, hardening/resource limits
match the Claude service, and web/hunter-mcp connectivity uses distinct
`assistant-rails-codex` and `assistant-codex-mcp` networks.

- [ ] **Step 2: Run Compose tests and verify RED**

Run: `cd web && bin/rails test test/config/assistant_compose_test.rb test/services/assistant/preflight_test.rb`

Expected: FAIL because the service and direct preflight targets are absent.

- [ ] **Step 3: Wire dev/prod Compose and preflight**

Add the service, named volume, internal Rails/MCP networks, provider-egress
network, seccomp, tmpfs, non-root user, caps, pids/memory/CPU limits, healthcheck,
and Rails environment. Replace gateway/validator preflight targets with Codex
and Claude direct endpoints; health remains advisory and token-free.

- [ ] **Step 4: Revise the failing real-binary contract for the approved boundary**

Keep the current failure from `TestRealCodexExposesOnlyReviewedHunterTools` as
the RED result: it reports the eight real built-ins instead of the obsolete
direct Hunter catalog. Rename the test to
`TestRealCodexEnforcesApprovedHunterMCPBoundary` and make the fake provider serve
two responses. The first response emits a client `tool_search_call` with call ID
`hunter-catalog`, query `hunter`, and limit `24`; the second emits the final
single-word assistant message. Capture both provider request bodies.

Assert the first request's sorted top-level names equal exactly:

```text
apply_patch
list_mcp_resource_templates
list_mcp_resources
read_mcp_resource
request_user_input
tool_search
update_plan
view_image
```

Also serialize and compare their complete stable type/name/schema categories so
a same-name schema change fails. In the second request, locate the sole
`tool_search_output` for `hunter-catalog`; assert `status=completed`,
`execution=client`, one namespace named `mcp__hunter`, and exactly the 24
reviewed child tool names/input-schema categories already listed in the test.
Assert the fake MCP request sequence remains `initialize`,
`notifications/initialized`, `tools/list`, with the exact bearer and turn-grant
headers. Remove the obsolete assertion that `apply_patch` and
`request_user_input` are forbidden; retain explicit rejection of shell/exec,
web/browser/computer, apps/plugins/skills, image generation, multi-agent, and
permission tools. Skip only when the exact pinned binary is unavailable; CI and
production evidence run it mandatorily in the built image.

- [ ] **Step 5: Add the real-binary immutable-workspace adversarial test**

Add `TestRealCodexApplyPatchCannotMutateReadOnlyWorkspace`. Reuse the production
invocation and fake provider configuration with no MCP server. Make the first
SSE response emit this custom call and complete:

```text
name: apply_patch
call_id: forbidden-patch
input: *** Begin Patch\n*** Add File: forbidden.txt\n+written\n*** End Patch
```

Make the second response return a final message. Use an otherwise writable
temporary working directory so the Codex sandbox—not Unix test-fixture
permissions—is the control under test. After Codex exits, assert
`forbidden.txt` does not exist and the second provider request contains the
failed `custom_tool_call_output` for `forbidden-patch`. This test must fail if
the production invocation loses `sandbox_mode="read-only"`. The separate image
inspection proves that `/workspace` is also immutable at the container layer.

- [ ] **Step 6: Verify contracts**

Run:

```bash
cd assistant/codex
gofmt -w internal/chat/tool_schema_contract_test.go
PATH=/usr/local/go/bin:$PATH go test ./internal/chat -run 'TestRealCodex(EnforcesApprovedHunterMCPBoundary|ApplyPatchCannotMutateReadOnlyWorkspace)' -count=1 -v
PATH=/usr/local/go/bin:$PATH go test ./...
cd ../../web
bin/rails test test/config/assistant_compose_test.rb test/services/assistant/preflight_test.rb
cd ..
docker compose config >/dev/null
docker compose -f docker-compose.prod.yaml config >/dev/null
docker build -t hunter-assistant-codex-task5 -f assistant/codex/Dockerfile assistant/codex
docker run --rm --entrypoint /bin/sh hunter-assistant-codex-task5 -c 'test "$(codex --version)" = "codex-cli 0.144.4" && test "$(id -u)" = "1000" && test ! -w /workspace'
git diff --check
```

Expected: both real-binary gates run rather than skip and pass; all Go and
focused Rails tests pass; both Compose files render without warning; the image
contains exact Codex 0.144.4, runs as uid 1000, and has an immutable workspace.
If Docker is unavailable, record the image/runtime commands as pending
production evidence without claiming them complete.

- [ ] **Step 7: Commit**

```bash
git add assistant/codex ops/assistant/seccomp/codex.json docker-compose.yaml docker-compose.prod.yaml .env.example web/app/services/assistant/preflight.rb web/test/config/assistant_compose_test.rb web/test/services/assistant/preflight_test.rb
git commit -m "Isolate the Codex Assistant runtime"
```

### Task 6: One-click logo chooser, provider identity, and Settings retirement

**Files:**
- Create: `web/app/javascript/lib/assistant_provider_picker.js`
- Create: `web/test/javascript/assistant_provider_picker_test.mjs`
- Create: `web/app/assets/images/assistant/openai.svg`
- Create: `web/app/assets/images/assistant/anthropic.svg`
- Modify: `web/app/javascript/lib/assistant_api.js`
- Modify: `web/app/javascript/lib/assistant_ui.js`
- Modify: `web/app/javascript/controllers/assistant_controller.js`
- Modify: `web/app/views/layouts/_assistant.html.erb`
- Modify: `web/app/views/settings/_assistant.html.erb`
- Modify: `web/app/controllers/settings_controller.rb`
- Modify: `web/test/javascript/assistant_api_test.mjs`
- Modify: `web/test/javascript/assistant_controller_test.mjs`
- Modify: `web/test/javascript/assistant_stimulus_controller_test.mjs`
- Modify: `web/test/integration/settings/assistant_test.rb`

**Interfaces:**
- Produces: `assistantApi.createConversation(backend)` → exact `{backend}` body
- Produces: Stimulus `startConversation(event)` reading only
  `event.currentTarget.dataset.backend`
- Consumes: safe bootstrap `chat_backends` descriptors.

- [ ] **Step 1: Write failing API/picker/UI tests**

Assert exact `{ backend: "codex" }`, two enabled reviewed descriptors in closed
order, unknown descriptors ignored, a double activation makes one request, both
buttons lock during the request, success focuses composer, error restores both,
and logo controls have accessible OpenAI/Anthropic names without visible model
text or a Start button.

Add message tests asserting an Assistant avatar receives the immutable
conversation brand; user remains independent; legacy gets archive identity and
a disabled composer.

- [ ] **Step 2: Run browser/settings tests and verify RED**

Run:

```bash
cd web
node --test test/javascript/assistant_api_test.mjs test/javascript/assistant_controller_test.mjs test/javascript/assistant_stimulus_controller_test.mjs test/javascript/assistant_provider_picker_test.mjs
bin/rails test test/integration/settings/assistant_test.rb
```

Expected: FAIL on old select/start/profile Settings behavior.

- [ ] **Step 3: Add locally served official brand SVGs**

Source the OpenAI and Anthropic marks from their official brand resources,
preserve license/attribution metadata in adjacent comments or documentation,
serve via Propshaft, and never fetch a logo at runtime. Use monochrome/current
color so Hunter light/dark surfaces control contrast.

- [ ] **Step 4: Replace dropdown/form with direct buttons**

Render two buttons with `data-backend`, `<%= image_tag %>`, `aria-label`, title,
and shared loading/status affordance. Remove `providerSelect`, retention select
change handling, and Start button targets. `startConversation` accepts only the
button slug and guards `conversationCreateInFlight`.

- [ ] **Step 5: Render pinned provider identity and legacy state**

Pass conversation backend/brand into `appendMessage`; construct logo `img`
elements only from the application's frozen brand→asset map, never a server URL.
Disable message input/send for `conversation.legacy === true` and show the
stable legacy explanation.

- [ ] **Step 6: Retire provider-profile Settings authoring**

Remove profile creation/catalog fields and arbitrary profile cards. Show two
read-only backend cards with login commands (`codex login --device-auth` and
`claude login`), subscription/retention disclosure, and no secret/profile CRUD
control. Keep the admin and Control Center revocation toggles.

- [ ] **Step 7: Run focused tests and commit**

Run the Step 2 commands and Tailwind build; expect all pass.

```bash
git add web/app/assets/images/assistant web/app/javascript web/app/views/layouts/_assistant.html.erb web/app/views/settings/_assistant.html.erb web/app/controllers/settings_controller.rb web/test
git commit -m "Add one-click direct Assistant provider selection"
```

### Task 7: Documentation, adversarial verification, and live smoke

**Files:**
- Modify: `docs/security/hunter-assistant-production-checklist.md`
- Create: `docs/runbooks/assistant-codex-mcp-smoke-test.md`
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-08-13-assistant-direct-provider-selection-design.md`
- Modify: this plan

**Interfaces:**
- Produces operator login, smoke, rollback, and version-bump instructions.

- [ ] **Step 1: Add checklist and runbook evidence fields**

Document exact login persistence, forced ChatGPT method, version/digest, network
inspection, the exact eight built-ins, the deferred Hunter MCP catalog capture,
the immutable-workspace patch denial, stable error demonstrations, legacy
rejection, metadata-only audit queries, real OpenAI/Anthropic turns, and rollback
that re-enables dormant gateway services without rewriting history.

- [ ] **Step 2: Run every automated suite**

```bash
cd web
node --test test/javascript/*.mjs
bin/rails test
bin/rails zeitwerk:check
bin/rails tailwindcss:build
bundle exec brakeman -q
cd ../assistant/codex && go test ./...
cd ../claude && go test ./...
cd ../mcp && go test ./...
cd ../gateway && go test ./...
cd ../validator && go test ./...
cd ../..
docker compose config >/dev/null
git diff --check
```

Expected: every command exits 0 with no test failures.

- [ ] **Step 3: Build and inspect both direct services**

Build both images; confirm pinned versions, non-root uid, mounts, networks,
healthchecks, and no API-key environment. Restart without deleting volumes and
confirm both login statuses persist.

- [ ] **Step 4: Run authenticated browser smoke through port 5000**

Verify: OpenAI/Anthropic one-click creation; duplicate-click lock; provider
avatar; new turn and resume for each; legacy transcript disabled; history rail;
compact/expand/copy code; history rename/reorder/delete; specific login failure;
no console errors from Assistant modules.

- [ ] **Step 5: Review audit and logs for canaries**

Use unique prompt/reply/grant/login canaries. Assert none appears in audit rows,
Rails/runner logs, API error bodies, or browser bootstrap. Assert normal
transcript storage contains only expected message bodies.

- [ ] **Step 6: Mark documents complete and commit**

Record exact commands/counts and any operator-only evidence still pending. Do
not mark production enabled unless every checklist item has actual evidence.

```bash
git add docs README.md
git commit -m "Complete direct Assistant provider documentation"
```
