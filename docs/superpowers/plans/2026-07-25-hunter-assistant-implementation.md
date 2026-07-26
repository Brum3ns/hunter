# Hunter Assistant Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an administrator-only, bottom-right Hunter chat that uses an isolated provider gateway and a dedicated read-only Go MCP broker to produce validated Whiterabbit-template and Ansible-playbook drafts that only Rails can save after explicit human confirmation.

**Architecture:** The browser talks only to Rails. Rails stores encrypted state and dispatches non-durable jobs through an isolated RabbitMQ vhost; a Go gateway calls one pinned OpenAI or Anthropic profile and uses a separate Go MCP service, while MCP alone calls grant-constrained sanitized Rails machine endpoints. Draft validation is effect-free, Ansible syntax checks run in a network-constrained validator, and confirmed saves return to ordinary Rails domain services without involving the gateway or MCP.

**Tech Stack:** Ruby 3.3.6, Rails 8.1.3, PostgreSQL, Active Record Encryption, MongoDB read services, Bunny 3.1.0, RabbitMQ 4, Hotwire/Stimulus/importmap, Go 1.25, official MCP Go SDK 1.6.0, official OpenAI Go SDK 3.37.0, official Anthropic Go SDK 1.61.0, `amqp091-go` 1.13.0, Ansible Core in a dedicated validator image, Docker Compose, Minitest, and Go's standard test/fuzz tooling.

## Global Constraints

- V1 browser access is limited to a cookie/session-authenticated user whose normalized username equals `ADMIN_USERNAME`; bearer authentication is rejected on every browser assistant endpoint.
- The gateway has no Hunter token. MCP has a dedicated digest-only `mcp_reader` identity and must present both that service token and the current opaque turn grant to Rails.
- Provider, gateway-to-MCP, MCP-to-Hunter, and per-service RabbitMQ credentials are distinct file-mounted secrets; raw values never enter Git, database rows, browser responses, queue logs, or application logs.
- Hunter has no integration, dependency, configuration, or runtime assumption tied to any external deployment-control product in development or production.
- A conversation is pinned to one enabled provider profile at creation and never silently changes provider or model.
- The provider receives only the user message, non-secret authoring policy, and explicitly selected records after versioned field allowlisting.
- V1 MCP tools are exactly `get_selected_context`, `get_artifact_example`, `get_authoring_policy`, `validate_whiterabbit_draft`, `validate_ansible_draft`, and `get_validation_result`.
- The gateway, MCP, and validator have no Hunter write, send, schedule, cancel, or execution capability. No generic HTTP, search, shell, filesystem, database, Docker, or arbitrary proxy tool is added.
- Turn grants default to a five-minute lifetime, ten selected records, eight tool calls, 64 KiB per result, and 256 KiB cumulative output; deployment settings may lower but never raise these code ceilings.
- Conversations use non-deterministic Active Record Encryption, expire after seven days by default with a configurable 1–30 day bound, and support immediate transactional deletion. Body-free audits default to 90 days.
- Provider endpoints are fixed to `https://api.openai.com` and `https://api.anthropic.com`; redirects, private destinations, arbitrary base URLs/headers, provider-hosted tools, background/batch modes, prompt caching, and provider fallback are disabled. OpenAI calls set `store: false`.
- Assistant-produced Whiterabbit content is not savable unless `CONTROL_CENTER_COMMAND_ALLOWLIST` is non-empty and every command is allowed. Assistant-produced Ansible content is not savable unless `ASSISTANT_ANSIBLE_MODULE_ALLOWLIST` is non-empty and all modules and constructs pass the assistant policy.
- All provider and MCP text is rendered with `textContent` or escaped ERB. Generated HTML is never injected.
- Production enablement remains off until container/network denial tests, rotation drills, dependency and image scans, and an independent security review have no unresolved critical or high findings.
- Do not commit during implementation unless the user explicitly authorizes commits. The conditional commit step in each task uses author `Claude <noreply@anthropic.com>` and a one-sentence message.

## File and Interface Map

The implementation is intentionally split into focused units:

- `web/app/models/assistant/` owns provider metadata, global settings, encrypted conversations/messages/drafts, turn grants, service identities, validation records, and metadata-only audits.
- `web/app/services/assistant/` owns configuration, admin policy, serializers, grant accounting, dispatch/event ingestion, draft policy, save confirmation, retention, and kill-switch behavior.
- `web/app/controllers/api/v1/assistant/` contains session-only browser JSON controllers. `machine/` contains MCP-only controllers with a different authenticator.
- `web/app/views/layouts/_assistant.html.erb`, `web/app/javascript/controllers/assistant_controller.js`, and `web/app/javascript/lib/assistant_api.js` own the global chat shell and browser state.
- `assistant/contracts/v1/` contains versioned JSON examples/schemas used as cross-language fixtures. No component forwards arbitrary Rails JSON.
- `assistant/mcp/` is the permanent Go MCP broker. `assistant/gateway/` is the Go provider/MCP client. `assistant/validator/` is the Ansible syntax-check worker. `assistant/egress/` contains the allowlisted proxy configuration.
- `ops/assistant/` contains secret generation, RabbitMQ-vhost provisioning, deployment verification, and rotation/incident scripts. These scripts never print secret contents after creation.

---

### Task 1: Security configuration, feature gate, and operating documents

**Files:**
- Create: `web/app/services/assistant/config.rb`
- Create: `web/app/services/assistant/admin_policy.rb`
- Create: `web/config/initializers/assistant.rb`
- Create: `web/test/services/assistant/config_test.rb`
- Create: `web/test/services/assistant/admin_policy_test.rb`
- Create: `docs/security/hunter-assistant-threat-model.md`
- Create: `docs/runbooks/hunter-assistant-incident-response.md`
- Create: `docs/runbooks/hunter-assistant-credential-rotation.md`
- Modify: `docker-compose.prod.yaml:1-16`

**Interfaces:**
- Produces: `Assistant::Config.enabled?`, `transcript_retention_days`, `audit_retention_days`, `grant_ttl`, `max_records`, `max_tool_calls`, `max_result_bytes`, and `max_total_bytes`.
- Produces: `Assistant::AdminPolicy.allowed?(user)` using normalized `ADMIN_USERNAME` equality.
- Produces: documented assets, threats, trust boundaries, incident severities, disable/revoke/rotate/re-enable order, and a provider/service/RabbitMQ credential rotation matrix.

- [ ] **Step 1: Write failing configuration and authorization tests**

```ruby
test "hard ceilings cannot be raised by environment configuration" do
  stub_methods(Assistant::Config, configured: ->(_key) { "999999" }) do
    assert_equal 300.seconds, Assistant::Config.grant_ttl
    assert_equal 10, Assistant::Config.max_records
    assert_equal 8, Assistant::Config.max_tool_calls
    assert_equal 65_536, Assistant::Config.max_result_bytes
    assert_equal 262_144, Assistant::Config.max_total_bytes
  end
end

test "only the normalized configured administrator is allowed" do
  user = User.new(username: "admin")
  stub_methods(Assistant::AdminPolicy, configured_username: -> { "admin" }) do
    assert Assistant::AdminPolicy.allowed?(user)
    refute Assistant::AdminPolicy.allowed?(User.new(username: "operator"))
    refute Assistant::AdminPolicy.allowed?(nil)
  end
end
```

- [ ] **Step 2: Run the tests and verify the missing constants fail**

Run: `cd web && bin/rails test test/services/assistant/config_test.rb test/services/assistant/admin_policy_test.rb`

Expected: FAIL with `uninitialized constant Assistant::Config` or `Assistant::AdminPolicy`.

- [ ] **Step 3: Implement immutable ceilings and fail-closed production startup**

```ruby
module Assistant
  module Config
    HARD = { grant_ttl: 300, max_records: 10, max_tool_calls: 8,
             max_result_bytes: 65_536, max_total_bytes: 262_144 }.freeze
    module_function

    def enabled? = ActiveModel::Type::Boolean.new.cast(ENV.fetch("ASSISTANT_ENABLED", "false"))
    def transcript_retention_days = bounded_integer("ASSISTANT_TRANSCRIPT_DAYS", 7, 1..30)
    def audit_retention_days = bounded_integer("ASSISTANT_AUDIT_DAYS", 90, 1..365)
    def grant_ttl = bounded_ceiling("ASSISTANT_GRANT_TTL_SECONDS", HARD[:grant_ttl]).seconds
    def max_records = bounded_ceiling("ASSISTANT_MAX_RECORDS", HARD[:max_records])
    def max_tool_calls = bounded_ceiling("ASSISTANT_MAX_TOOL_CALLS", HARD[:max_tool_calls])
    def max_result_bytes = bounded_ceiling("ASSISTANT_MAX_RESULT_BYTES", HARD[:max_result_bytes])
    def max_total_bytes = bounded_ceiling("ASSISTANT_MAX_TOTAL_BYTES", HARD[:max_total_bytes])

    def configured(key) = ENV[key]

    def bounded_ceiling(key, ceiling)
      [[Integer(configured(key) || ceiling), 1].max, ceiling].min
    rescue ArgumentError, TypeError
      ceiling
    end

    def bounded_integer(key, default, range)
      value = Integer(configured(key) || default)
      raise ArgumentError, "#{key} must be in #{range}" unless range.cover?(value)
      value
    end
  end
end
```

The initializer must abort production boot when `ASSISTANT_ENABLED=true` and `ADMIN_USERNAME` is blank, any retention value is out of range, or either assistant authoring allowlist is missing. Development may boot with the feature disabled and missing secrets.

- [ ] **Step 4: Write the threat model and runbooks with executable verification commands**

Record the exact data flow from the approved spec, every credential's readers, the kill-switch sequence, and commands such as `docker compose config`, `docker compose ps`, `docker inspect`, and the task names added later in this plan. Replace the stale production-Compose header with a product-neutral description; do not add deployment-product configuration.

- [ ] **Step 5: Run focused and boot tests**

Run: `cd web && bin/rails test test/services/assistant/config_test.rb test/services/assistant/admin_policy_test.rb test/config/active_record_encryption_test.rb`

Expected: PASS.

- [ ] **Step 6: Conditionally commit after explicit authorization**

```bash
git config user.name Claude
git config user.email noreply@anthropic.com
git add web/app/services/assistant web/config/initializers/assistant.rb web/test/services/assistant docs/security docs/runbooks docker-compose.prod.yaml
git commit -m "Add assistant security configuration and operating guidance."
```

### Task 2: Provider profiles and global assistant settings

**Files:**
- Create: `web/db/migrate/20260725010001_create_assistant_configuration.rb`
- Create: `web/app/models/assistant/provider_profile.rb`
- Create: `web/app/models/assistant/setting.rb`
- Create: `web/config/assistant_provider_catalog.yml`
- Create: `web/app/services/assistant/provider_catalog.rb`
- Create: `web/test/models/assistant/provider_profile_test.rb`
- Create: `web/test/models/assistant/setting_test.rb`
- Create: `web/test/services/assistant/provider_catalog_test.rb`
- Create: `web/test/fixtures/assistant_provider_profiles.yml`
- Create: `web/test/fixtures/assistant_settings.yml`
- Modify: `web/app/models/user.rb`

**Interfaces:**
- Produces: `Assistant::ProviderCatalog.fetch!(slug)` returning an immutable entry with `provider`, `model`, `secret_ref`, `input_limit`, `output_limit`, and `retention_posture`.
- Produces: `Assistant::ProviderProfile#dispatch_snapshot` containing non-secret approved metadata only.
- Produces: `Assistant::Setting.instance`, `.assistant_enabled?`, `.disable!`, and `.enable!`.

- [ ] **Step 1: Add failing model tests for catalog-only profiles and bounded retention**

```ruby
test "profile derives endpoint-sensitive fields from the reviewed catalog" do
  profile = Assistant::ProviderProfile.new(name: "Primary", catalog_slug: "openai_primary", created_by: users(:one))
  assert profile.valid?
  assert_equal "openai", profile.provider
  assert_equal "openai_primary", profile.secret_ref
  refute_includes profile.dispatch_snapshot.keys, :api_key
  refute_includes profile.dispatch_snapshot.keys, :base_url
end

test "settings enforce transcript and audit bounds" do
  setting = Assistant::Setting.new(transcript_retention_days: 31, audit_retention_days: 90)
  refute setting.valid?
  assert_includes setting.errors[:transcript_retention_days], "must be in 1..30"
end
```

- [ ] **Step 2: Run the tests and verify they fail before the migration/models exist**

Run: `cd web && bin/rails test test/models/assistant/provider_profile_test.rb test/models/assistant/setting_test.rb test/services/assistant/provider_catalog_test.rb`

Expected: FAIL on missing tables/classes.

- [ ] **Step 3: Add the configuration migration**

Create `assistant_provider_profiles` with `name`, `catalog_slug`, `provider`, `model`, `secret_ref`, `enabled`, `input_limit`, `output_limit`, `tool_call_limit`, `retention_posture`, `reviewed_at`, `created_by_id`, timestamps, and unique lower-name/catalog indexes. Create singleton `assistant_settings` with a unique, always-true `singleton_key`, `assistant_enabled` default false, transcript days default 7, audit days default 90, `disabled_at`, `disabled_by_id`, and timestamps. Add foreign keys to users and `has_many :assistant_provider_profiles` to `User`.

- [ ] **Step 4: Add a closed provider catalog and reject arbitrary endpoint data**

```yaml
openai_primary:
  provider: openai
  model: gpt-5
  secret_ref: openai_primary
  input_limit: 32768
  output_limit: 8192
  retention_posture: standard
anthropic_primary:
  provider: anthropic
  model: claude-sonnet-5
  secret_ref: anthropic_primary
  input_limit: 32768
  output_limit: 8192
  retention_posture: standard
```

`Assistant::ProviderProfile` must copy catalog fields on validation, reject unknown slugs, validate `tool_call_limit` in `1..8`, and never accept a URL or header column. Provider/model changes require selecting another reviewed catalog entry and starting a new conversation.

- [ ] **Step 5: Migrate and rerun focused tests**

Run: `cd web && bin/rails db:migrate && bin/rails test test/models/assistant/provider_profile_test.rb test/models/assistant/setting_test.rb test/services/assistant/provider_catalog_test.rb`

Expected: PASS and `db/schema.rb` contains both assistant configuration tables.

- [ ] **Step 6: Conditionally commit after explicit authorization**

```bash
git add web/db/migrate/20260725010001_create_assistant_configuration.rb web/db/schema.rb web/app/models/assistant web/app/services/assistant/provider_catalog.rb web/config/assistant_provider_catalog.yml web/test/models/assistant web/test/services/assistant/provider_catalog_test.rb web/test/fixtures/assistant_provider_profiles.yml web/test/fixtures/assistant_settings.yml web/app/models/user.rb
git commit -m "Add approved assistant provider profiles and settings."
```

### Task 3: Encrypted conversations, turns, messages, contexts, and drafts

**Files:**
- Create: `web/db/migrate/20260725010002_create_assistant_conversations.rb`
- Create: `web/app/models/assistant/conversation.rb`
- Create: `web/app/models/assistant/turn.rb`
- Create: `web/app/models/assistant/message.rb`
- Create: `web/app/models/assistant/context_reference.rb`
- Create: `web/app/models/assistant/draft.rb`
- Create: `web/test/models/assistant/conversation_test.rb`
- Create: `web/test/models/assistant/turn_test.rb`
- Create: `web/test/models/assistant/message_test.rb`
- Create: `web/test/models/assistant/draft_test.rb`
- Create: `web/test/fixtures/assistant_conversations.yml`
- Create: `web/test/fixtures/assistant_turns.yml`
- Create: `web/test/fixtures/assistant_messages.yml`
- Create: `web/test/fixtures/assistant_context_references.yml`
- Create: `web/test/fixtures/assistant_drafts.yml`
- Modify: `web/app/models/user.rb`

**Interfaces:**
- Produces: `Assistant::Conversation.start!(user:, provider_profile:)`, `#append_user_turn!(body:, context_refs:)`, and `#destroy_with_content!`.
- Produces: turn states `created`, `queued`, `running`, `completed`, `failed`, `canceled`, and `interrupted`.
- Produces: draft types `whiterabbit_template` and `ansible_playbook`; draft content, validation details, and message bodies are encrypted.

- [ ] **Step 1: Write failing ownership, pinning, encryption, and cascade tests**

```ruby
test "conversation pins its profile and encrypts message bodies" do
  conversation = Assistant::Conversation.start!(user: users(:one), provider_profile: assistant_provider_profiles(:openai))
  turn = conversation.append_user_turn!(body: "draft a probe", context_refs: [])
  raw = ActiveRecord::Base.connection.select_value("SELECT body FROM assistant_messages WHERE id = #{turn.user_message.id}")
  refute_includes raw, "draft a probe"
  assert_equal conversation.provider_profile_id, turn.provider_profile_id
end

test "destroy_with_content removes messages drafts and contexts atomically" do
  conversation = assistant_conversations(:one)
  assert_difference -> { Assistant::Conversation.count }, -1 do
    conversation.destroy_with_content!
  end
  assert_empty Assistant::Message.where(conversation_id: conversation.id)
  assert_empty Assistant::Draft.where(conversation_id: conversation.id)
end
```

- [ ] **Step 2: Run tests and confirm missing persistence fails**

Run: `cd web && bin/rails test test/models/assistant/conversation_test.rb test/models/assistant/turn_test.rb test/models/assistant/message_test.rb test/models/assistant/draft_test.rb`

Expected: FAIL on missing tables.

- [ ] **Step 3: Add the conversation schema with explicit ownership and limits**

Create tables with these essential columns: conversations (`user_id`, `provider_profile_id`, `status`, `title`, `expires_at`); turns (`conversation_id`, `user_id`, `provider_profile_id`, UUID `correlation_id`, `status`, `error_code`, timing and token counters); messages (`conversation_id`, `turn_id`, `role`, encrypted `body`, `sequence`); context references (`turn_id`, `resource_type`, `resource_id`, `label`, `serializer_version`); drafts (`conversation_id`, `turn_id`, `artifact_type`, `name`, encrypted `content`, encrypted `validation_details`, `validation_status`, `validation_version`, `content_digest`, destination type/id/lock-version). Add foreign keys, unique `(conversation_id, sequence)`, unique correlation IDs, and indexes on ownership, state, and expiry.

- [ ] **Step 4: Implement non-deterministic encryption and immutable profile binding**

```ruby
class Assistant::Message < ApplicationRecord
  encrypts :body
  belongs_to :conversation, class_name: "Assistant::Conversation"
  belongs_to :turn, class_name: "Assistant::Turn", optional: true
  validates :role, inclusion: { in: %w[user assistant system_event] }
  validates :body, length: { maximum: 65_536 }
end

class Assistant::Draft < ApplicationRecord
  encrypts :content
  encrypts :validation_details
  validates :artifact_type, inclusion: { in: %w[whiterabbit_template ansible_playbook] }
end
```

Reject profile reassignment after creation. Set expiration from the bounded setting. A conversation deletion uses one database transaction and hard-deletes content rows; body-free audit rows retain nullable references.

- [ ] **Step 5: Migrate, inspect ciphertext, and run the model suite**

Run: `cd web && bin/rails db:migrate && bin/rails test test/models/assistant/conversation_test.rb test/models/assistant/turn_test.rb test/models/assistant/message_test.rb test/models/assistant/draft_test.rb`

Expected: PASS, and the raw SQL assertion proves plaintext is absent.

- [ ] **Step 6: Conditionally commit after explicit authorization**

```bash
git add web/db/migrate/20260725010002_create_assistant_conversations.rb web/db/schema.rb web/app/models/assistant web/test/models/assistant web/test/fixtures/assistant_conversations.yml web/test/fixtures/assistant_turns.yml web/test/fixtures/assistant_messages.yml web/test/fixtures/assistant_context_references.yml web/test/fixtures/assistant_drafts.yml web/app/models/user.rb
git commit -m "Add encrypted assistant conversations and drafts."
```

### Task 4: Digest-only service identities, turn grants, and metadata audits

**Files:**
- Create: `web/db/migrate/20260725010003_create_assistant_security_records.rb`
- Create: `web/app/models/assistant/service_identity.rb`
- Create: `web/app/models/assistant/turn_grant.rb`
- Create: `web/app/models/assistant/audit_event.rb`
- Create: `web/app/services/assistant/grants/issuer.rb`
- Create: `web/app/services/assistant/grants/authorizer.rb`
- Create: `web/app/services/assistant/audit.rb`
- Create: `web/lib/tasks/assistant_service_tokens.rake`
- Create: `web/test/models/assistant/service_identity_test.rb`
- Create: `web/test/services/assistant/grants/authorizer_test.rb`
- Create: `web/test/services/assistant/audit_test.rb`
- Create: `web/test/lib/tasks/assistant_service_tokens_test.rb`
- Modify: `web/config/initializers/filter_parameter_logging.rb`

**Interfaces:**
- Produces: `Assistant::ServiceIdentity.generate!(name:, role:) -> [record, raw_token]` and `.authenticate(raw, role:)`.
- Produces: `Assistant::Grants::Issuer.call(turn:, resources:, tools:) -> raw_grant`.
- Produces: `Assistant::Grants::Authorizer.reserve!(raw_grant:, tool:, resource_type: nil, resource_id: nil) -> Reservation`; `Reservation#complete!(bytes:)` and `#fail!`.
- Produces: `Assistant::Audit.record!(event:, attributes:)` with a closed key allowlist.

- [ ] **Step 1: Write failing digest, expiry, resource, concurrency, and audit-body rejection tests**

```ruby
test "issuer stores only a digest and exact resources" do
  raw = Assistant::Grants::Issuer.call(turn: assistant_turns(:created),
    resources: [{ type: "target", id: "abc" }], tools: ["get_selected_context"])
  grant = Assistant::TurnGrant.last
  refute_equal raw, grant.token_digest
  assert_equal Digest::SHA256.hexdigest(raw), grant.token_digest
  assert_equal [{ "type" => "target", "id" => "abc" }], grant.resources
end

test "audit rejects body-bearing attributes" do
  assert_raises(ArgumentError) { Assistant::Audit.record!(event: "tool.called", attributes: { prompt: "secret" }) }
end
```

- [ ] **Step 2: Run focused tests and confirm they fail**

Run: `cd web && bin/rails test test/models/assistant/service_identity_test.rb test/services/assistant/grants/authorizer_test.rb test/services/assistant/audit_test.rb test/lib/tasks/assistant_service_tokens_test.rb`

Expected: FAIL on missing security records.

- [ ] **Step 3: Add security tables and pessimistic byte reservations**

Create service identities with `name`, `role`, unique `token_digest`, `enabled`, `last_used_at`, `rotated_at`. Create grants with exact user/conversation/turn/profile foreign keys, unique digest, JSON resource list, tool string array, `expires_at`, `max_calls`, `call_count`, `max_result_bytes`, `max_total_bytes`, `returned_bytes`, `reserved_bytes`, `revoked_at`, and lock version. Create audits with correlation and foreign-key identifiers, event/status/model/tool/resource metadata, byte/token/latency counters, validation codes, content hashes, target references, JSON metadata, and `expires_at`; there are no body columns.

`reserve!` must lock the grant row, verify identity bindings, expiry/revocation/tool/resource, increment `call_count`, and reserve `max_result_bytes` before releasing the lock. `complete!` replaces the reservation with actual bytes; a result exceeding per-call or cumulative limits is discarded, audited, and revokes the grant.

- [ ] **Step 4: Implement constant-time token comparison and one-time token output**

Use `ActiveSupport::SecurityUtils.secure_compare` on SHA-256 digests. The rake task accepts only role `mcp_reader`, prints the raw token once to stdout, never logs it, and refuses duplicate enabled names without `ROTATE=true`. Rotation disables the old row before creating the new token.

- [ ] **Step 5: Expand parameter filtering and verify logs**

Add `:turn_grant`, `:service_token`, `:authorization`, `:provider_response`, `:message_body`, `:draft_content`, and `:validation_details` to filtered parameters. Add a request-log assertion that raw grant and service token strings become `[FILTERED]`.

- [ ] **Step 6: Run migrations and security tests**

Run: `cd web && bin/rails db:migrate && bin/rails test test/models/assistant/service_identity_test.rb test/services/assistant/grants/authorizer_test.rb test/services/assistant/audit_test.rb test/lib/tasks/assistant_service_tokens_test.rb`

Expected: PASS, including two-thread reservation tests proving limits cannot be overrun.

- [ ] **Step 7: Conditionally commit after explicit authorization**

```bash
git add web/db/migrate/20260725010003_create_assistant_security_records.rb web/db/schema.rb web/app/models/assistant web/app/services/assistant/grants web/app/services/assistant/audit.rb web/lib/tasks/assistant_service_tokens.rake web/config/initializers/filter_parameter_logging.rb web/test
git commit -m "Add assistant service identities grants and metadata audits."
```

### Task 5: Session-only assistant API and provider administration

**Files:**
- Create: `web/app/controllers/api/v1/assistant/base_controller.rb`
- Create: `web/app/controllers/api/v1/assistant/bootstrap_controller.rb`
- Create: `web/app/controllers/api/v1/assistant/conversations_controller.rb`
- Create: `web/app/controllers/api/v1/assistant/provider_profiles_controller.rb`
- Create: `web/app/controllers/api/v1/assistant/settings_controller.rb`
- Create: `web/test/integration/api/v1/assistant/authentication_test.rb`
- Create: `web/test/integration/api/v1/assistant/provider_profiles_test.rb`
- Create: `web/test/integration/api/v1/assistant/conversations_test.rb`
- Create: `web/app/views/settings/_assistant.html.erb`
- Create: `web/test/integration/settings/assistant_test.rb`
- Modify: `web/app/controllers/settings_controller.rb`
- Modify: `web/app/views/settings/show.html.erb`
- Modify: `web/config/routes.rb`
- Create: `web/config/openapi/assistant.yaml`

**Interfaces:**
- Produces browser routes: `GET /api/v1/assistant/bootstrap`, CRUD conversations, CRUD provider profiles, and `PATCH /api/v1/assistant/settings`.
- Produces a JSON base controller that rejects any `Authorization` header, requires the session cookie, checks `Assistant::AdminPolicy`, and preserves Rails CSRF protection.

- [ ] **Step 1: Write integration tests for anonymous, non-admin, bearer, CSRF, disabled-profile, and ownership cases**

```ruby
test "valid bearer token is rejected on the browser assistant API" do
  _record, raw = ApiToken.generate(user: users(:one), name: "all", scopes: ["*"])
  get "/api/v1/assistant/bootstrap", headers: { "Authorization" => "Bearer #{raw}" }
  assert_response :unauthorized
  assert_equal "session_required", response.parsed_body["error"]
end

test "conversation pins an enabled profile owned by the admin session" do
  sign_in_as(users(:one))
  post "/api/v1/assistant/conversations", params: { provider_profile_id: assistant_provider_profiles(:openai).id }, as: :json
  assert_response :created
  assert_equal assistant_provider_profiles(:openai).id, response.parsed_body["provider_profile"]["id"]
end
```

- [ ] **Step 2: Run tests and verify routes/controllers are absent**

Run: `cd web && bin/rails test test/integration/api/v1/assistant/authentication_test.rb test/integration/api/v1/assistant/provider_profiles_test.rb test/integration/api/v1/assistant/conversations_test.rb`

Expected: FAIL with routing errors.

- [ ] **Step 3: Add explicit routes and the isolated browser base controller**

```ruby
namespace :assistant do
  get "bootstrap", to: "bootstrap#show"
  resources :conversations, only: %i[index show create destroy]
  resources :provider_profiles, except: %i[new edit]
  resource :settings, only: %i[show update]
end
```

Override authentication rather than inheriting bearer fallback: reject a present authorization header, call `resume_session`, require `Current.session.user`, then require `Assistant::AdminPolicy.allowed?`. Return stable `401 session_required` and `403 assistant_admin_required` envelopes. Keep bootstrap/profile/settings routes available to the administrator while disabled; only conversation creation and later dispatch routes apply `require_assistant_enabled!` and return `503 assistant_disabled`. Effective enablement requires both the infrastructure gate `Assistant::Config.enabled?` and the database setting.

- [ ] **Step 4: Implement strong-parameter profile/settings/conversation actions**

Profiles accept only `name`, `catalog_slug`, `enabled`, `tool_call_limit`, `retention_posture`, and `reviewed_at`; serialize no endpoint or secret path. Settings accept only `assistant_enabled`, `transcript_retention_days`, and `audit_retention_days`. Conversation creation accepts one profile ID and rejects disabled/unreviewed profiles.

- [ ] **Step 5: Add the administrator-only Assistant section to Hunter settings**

Load assistant settings/profiles only when `Assistant::AdminPolicy.allowed?(Current.user)`. The partial shows enabled state, bounded retention, catalog-backed profile metadata, review timestamp, retention posture, and a kill-switch warning. Forms submit only to the session-only JSON routes with CSRF; no secret value, file path, base URL, or arbitrary header field is displayed or accepted.

- [ ] **Step 6: Document the browser endpoints and run OpenAPI coverage**

Document session-cookie security, CSRF errors, admin errors, and body schemas in `assistant.yaml`. Do not document machine service tokens as normal bearer auth. Mark these operations with `x-session-only: true` and no `x-api-scope`.

Run: `cd web && bin/rails test test/integration/api/v1/assistant test/integration/settings/assistant_test.rb test/services/api_docs/spec_test.rb test/services/api_docs/coverage_test.rb`

Expected: PASS with every new route covered.

- [ ] **Step 7: Conditionally commit after explicit authorization**

```bash
git add web/app/controllers/api/v1/assistant web/test/integration/api/v1/assistant web/app/views/settings web/test/integration/settings/assistant_test.rb web/app/controllers/settings_controller.rb web/config/routes.rb web/config/openapi/assistant.yaml
git commit -m "Add the session-only assistant administration API."
```

### Task 6: Global accessible chat shell with model selection

**Files:**
- Create: `web/app/views/layouts/_assistant.html.erb`
- Create: `web/app/javascript/controllers/assistant_controller.js`
- Create: `web/app/javascript/lib/assistant_api.js`
- Create: `web/test/integration/assistant_shell_test.rb`
- Create: `web/test/javascript/assistant_api_test.mjs`
- Modify: `web/app/views/layouts/application.html.erb`
- Modify: `web/app/javascript/controllers/index.js`

**Interfaces:**
- Produces: collapsed bubble, docked panel, provider/retention start screen, conversation list, message form, disclosure preview, and empty draft-card region.
- Consumes: `GET /api/v1/assistant/bootstrap` and conversation CRUD from Task 5.

- [ ] **Step 1: Write failing rendering and browser-client tests**

```ruby
test "assistant shell renders only for the configured session administrator" do
  sign_in_as(users(:one))
  get root_path
  assert_select "[data-controller='assistant']", count: 1
  assert_select "button[aria-label='Open Hunter assistant']", count: 1
end
```

```javascript
test("assistantApi sends same-origin JSON with the CSRF token", async () => {
  const request = captureFetch()
  await assistantApi.createConversation(7)
  assert.equal(request.url, "/api/v1/assistant/conversations")
  assert.equal(request.options.headers["X-CSRF-Token"], "csrf-test")
  assert.equal(request.options.credentials, "same-origin")
})
```

- [ ] **Step 2: Run Rails and JavaScript tests and verify failure**

Run: `cd web && bin/rails test test/integration/assistant_shell_test.rb && node --test test/javascript/assistant_api_test.mjs`

Expected: FAIL because the partial and module do not exist.

- [ ] **Step 3: Add escaped, keyboard-accessible markup**

Render the partial only when authenticated and `Assistant::AdminPolicy.allowed?(Current.user)`. Use `aria-expanded`, `aria-controls`, Escape-to-close, focus return, focus trapping on mobile, responsive full-height layout, and a retention notice before conversation creation. Keep the toaster above the bubble by moving its bottom offset while the assistant is present.

- [ ] **Step 4: Add a same-origin client and Stimulus state controller**

Use `textContent` for message bodies and code blocks; build elements with `document.createElement`; never assign provider output to `innerHTML`. On Turbo disconnect, abort polling and provider-independent requests. Do not store transcript content in localStorage/sessionStorage.

- [ ] **Step 5: Run accessibility-oriented assertions and existing JavaScript tests**

Run: `cd web && bin/rails test test/integration/assistant_shell_test.rb && node --test test/javascript/*.mjs`

Expected: PASS.

- [ ] **Step 6: Conditionally commit after explicit authorization**

```bash
git add web/app/views/layouts web/app/javascript/controllers/assistant_controller.js web/app/javascript/controllers/index.js web/app/javascript/lib/assistant_api.js web/test/integration/assistant_shell_test.rb web/test/javascript/assistant_api_test.mjs
git commit -m "Add the administrator-only assistant chat shell."
```

### Task 7: Explicit context picker and versioned sanitizers

**Files:**
- Create: `web/app/services/assistant/context/resolver.rb`
- Create: `web/app/services/assistant/context/catalog.rb`
- Create: `web/app/services/assistant/context/secret_detector.rb`
- Create: `web/app/services/assistant/context/serializers/base.rb`
- Create: `web/app/services/assistant/context/serializers/program.rb`
- Create: `web/app/services/assistant/context/serializers/target.rb`
- Create: `web/app/services/assistant/context/serializers/cve.rb`
- Create: `web/app/services/assistant/context/serializers/vulnerability.rb`
- Create: `web/app/services/assistant/context/serializers/whiterabbit_template.rb`
- Create: `web/app/services/assistant/context/serializers/ansible_playbook.rb`
- Create: `web/app/controllers/api/v1/assistant/context_options_controller.rb`
- Create: `web/app/controllers/api/v1/assistant/context_previews_controller.rb`
- Create: `web/test/services/assistant/context/serializers_test.rb`
- Create: `web/test/integration/api/v1/assistant/context_test.rb`
- Create: `web/test/fixtures/files/assistant_adversarial_contexts.yml`
- Modify: `web/config/routes.rb`
- Modify: `web/config/openapi/assistant.yaml`

**Interfaces:**
- Produces: `Assistant::Context::Resolver.find(type:, id:, user:)` and `.options(type:, query:, user:, limit: 20)`.
- Produces: `Assistant::Context::Catalog.serialize!(type:, record:) -> { schema_version: 1, type:, id:, data: }` with a 32 KiB serialized ceiling.
- Produces browser-only `GET context_options` and `POST context_previews`; neither grants model access by itself.

- [ ] **Step 1: Write failing exact-field and secret-rejection tests for all six types**

```ruby
test "target serializer strips URL credentials query fragment headers and raw attributes" do
  target = Target.new("id" => "a", "target" => { "url" => "https://u:p@example.test/x?token=s#f", "host" => "example.test", "port" => 443, "scheme" => "https", "path" => "/x", "method" => "GET" }, "headers" => { "authorization" => "Bearer secret" })
  result = Assistant::Context::Catalog.serialize!(type: "target", record: target)
  assert_equal "https://example.test/x", result.dig(:data, :url)
  refute_includes result.to_json, "Bearer"
  refute_includes result.to_json, "token="
  refute result[:data].key?(:headers)
end
```

- [ ] **Step 2: Run focused tests and confirm serializers are absent**

Run: `cd web && bin/rails test test/services/assistant/context/serializers_test.rb test/integration/api/v1/assistant/context_test.rb`

Expected: FAIL on missing catalog/controllers.

- [ ] **Step 3: Implement explicit V1 field sets and bounds**

Use these output sets only: program (`sid`, `name`, `platform`, `status`, `public`, `bounty`, `currency`, bounded tags/languages/plain-text description); target (`id`, sanitized URL, `host`, `port`, `scheme`, bounded path, `method`, status/title/webserver/tech/program); CVE (`Cve#as_core_json` intersected with `CORE_FIELDS` plus bounded chain); vulnerability (`id`, metadata program/tool/date, report title/status, finding name/type/severity, target host/sanitized URL/method, no PoC); template (`id`, name/kind/tags/description/output/commands/target/updated_at); playbook (`id`, name/description/yaml/checksum/updated_at, no variable sets). Unknown keys are impossible because serializers construct new hashes.

Reject an artifact example rather than redacting it when secret detection matches private-key markers, bearer/basic credentials, common token assignments, cloud access-key shapes, URL userinfo, vault blocks, or values exceeding bounds. Normalize URLs by removing userinfo, query, and fragment.

- [ ] **Step 4: Implement bounded human-facing options and previews**

Options return at most 20 `{type,id,label}` rows and use existing read services; no raw document leaves the controller. Preview accepts at most ten exact `{type,id}` references, resolves them under `Current.user`, and returns the same sanitized body that a grant would authorize. Invalid/missing entries fail the whole request with stable per-reference codes.

- [ ] **Step 5: Run serializer, integration, and API coverage tests**

Run: `cd web && bin/rails test test/services/assistant/context/serializers_test.rb test/integration/api/v1/assistant/context_test.rb test/services/api_docs/coverage_test.rb`

Expected: PASS, including every forbidden fixture field.

- [ ] **Step 6: Conditionally commit after explicit authorization**

```bash
git add web/app/services/assistant/context web/app/controllers/api/v1/assistant/context_* web/test/services/assistant/context web/test/integration/api/v1/assistant/context_test.rb web/test/fixtures/files/assistant_adversarial_contexts.yml web/config/routes.rb web/config/openapi/assistant.yaml
git commit -m "Add explicit assistant context selection and sanitization."
```

### Task 8: MCP-only Rails machine API with double authorization

**Files:**
- Create: `web/app/controllers/api/v1/assistant/machine/base_controller.rb`
- Create: `web/app/controllers/api/v1/assistant/machine/grants_controller.rb`
- Create: `web/app/controllers/api/v1/assistant/machine/contexts_controller.rb`
- Create: `web/app/controllers/api/v1/assistant/machine/artifacts_controller.rb`
- Create: `web/app/controllers/api/v1/assistant/machine/policies_controller.rb`
- Create: `web/app/controllers/api/v1/assistant/machine/validations_controller.rb`
- Create: `web/app/services/assistant/machine_authenticator.rb`
- Create: `web/test/integration/api/v1/assistant/machine/authorization_test.rb`
- Create: `web/test/integration/api/v1/assistant/machine/tools_test.rb`
- Modify: `web/app/models/current.rb`
- Modify: `web/config/routes.rb`
- Modify: `web/config/openapi/assistant.yaml`

**Interfaces:**
- Produces machine routes for grant introspection, exact context/artifact fetch, policy fetch, draft validation submission, and validation-result fetch.
- Consumes headers `Authorization: Bearer <mcp-reader-token>` and `X-Hunter-Turn-Grant: <opaque-grant>` on every tool route.
- Returns only stable codes, closed response bodies, correlation IDs, and grant-budget headers.

- [ ] **Step 1: Write failing tests for token-only, grant-only, wrong-role, arbitrary-ID, expired, replayed, and ordinary-route access**

```ruby
test "service identity without a turn grant cannot read context" do
  get "/api/v1/assistant/machine/contexts/target/abc", headers: service_headers
  assert_response :forbidden
  assert_equal "invalid_turn_grant", response.parsed_body["error"]
end

test "mcp service token cannot authenticate an ordinary module route" do
  get "/api/v1/vulnerabilities", headers: { "Authorization" => "Bearer #{raw_mcp_token}" }
  assert_response :unauthorized
end
```

- [ ] **Step 2: Run tests and verify machine routes are absent**

Run: `cd web && bin/rails test test/integration/api/v1/assistant/machine`

Expected: FAIL with routing errors.

- [ ] **Step 3: Implement machine authentication while preserving the v1 controller convention**

Subclass `Api::V1::BaseController`, override its authentication hook to authenticate only `Assistant::ServiceIdentity.authenticate(raw, role: "mcp_reader")`, and store the result in a new `Current.assistant_service_identity` attribute. Do not call normal bearer/session authentication; reject cookies and normal `ApiToken` values; require the turn grant separately. Limit bodies before JSON parsing, force JSON content type, return `Cache-Control: no-store`, and never echo credentials.

- [ ] **Step 4: Enforce the same grant in Rails for every tool operation**

Introspection returns grant ID, correlation ID, allowed tools/resources, expiry, and remaining budgets. Every other action calls `Assistant::Grants::Authorizer.reserve!` with the exact MCP tool and resource, resolves through Task 7, serializes, measures `JSON.generate(body).bytesize`, then calls `complete!`. Any mismatch discards the body and returns a stable error.

- [ ] **Step 5: Document machine paths as a separate security scheme and run tests**

OpenAPI defines `AssistantServiceToken` plus required `X-Hunter-Turn-Grant`, marks routes `x-internal-machine: true`, and states that this credential is invalid on every other Hunter path.

Run: `cd web && bin/rails test test/integration/api/v1/assistant/machine test/services/api_docs/coverage_test.rb`

Expected: PASS.

- [ ] **Step 6: Conditionally commit after explicit authorization**

```bash
git add web/app/controllers/api/v1/assistant/machine web/app/services/assistant/machine_authenticator.rb web/app/models/current.rb web/test/integration/api/v1/assistant/machine web/config/routes.rb web/config/openapi/assistant.yaml
git commit -m "Add the grant-constrained assistant machine API."
```

### Task 9: Versioned queue contracts and isolated RabbitMQ topology

**Files:**
- Modify: `web/Gemfile`
- Modify: `web/Gemfile.lock`
- Create: `assistant/contracts/v1/turn_job.json`
- Create: `assistant/contracts/v1/assistant_event.json`
- Create: `assistant/contracts/v1/validation_job.json`
- Create: `assistant/contracts/v1/validation_event.json`
- Create: `web/app/services/assistant/broker.rb`
- Create: `web/app/services/assistant/turn_dispatcher.rb`
- Create: `web/app/services/assistant/event_ingestor.rb`
- Create: `web/app/services/assistant/event_consumer.rb`
- Create: `ops/assistant/provision_rabbitmq.rb`
- Create: `web/test/services/assistant/turn_dispatcher_test.rb`
- Create: `web/test/services/assistant/event_ingestor_test.rb`
- Create: `web/test/contracts/assistant_queue_contracts_test.rb`
- Modify: `web/Procfile.dev`
- Modify: `web/Procfile.prod`

**Interfaces:**
- Produces non-durable direct exchanges/queues in vhost `/hunter-assistant`: `assistant.turns` -> `assistant.gateway.turns`, `assistant.events` -> `assistant.rails.events`, `assistant.validations` -> `assistant.validator.requests`, and `assistant.validation_events` -> `assistant.rails.validation_events`.
- Produces: `Assistant::TurnDispatcher.call(turn:, raw_grant:)` and `Assistant::EventIngestor.call(payload)`.
- Queue bodies carry `schema_version: 1`, UUID correlation ID, IDs/non-secret snapshots, raw turn grant only where required, and expiry; they never carry service or provider credentials.

- [ ] **Step 1: Add Bunny 3.1.0 and write contract/publisher tests first**

```ruby
test "turn message is non-persistent and excludes all service credentials" do
  delivery = capture_publish { Assistant::TurnDispatcher.call(turn: assistant_turns(:created), raw_grant: "grant-value") }
  assert_equal false, delivery[:persistent]
  assert_equal 300_000, delivery[:expiration]
  assert_equal 1, delivery[:body]["schema_version"]
  refute_includes delivery[:body].to_json, "provider_api_key"
  refute_includes delivery[:body].to_json, "mcp_service_token"
end
```

- [ ] **Step 2: Run tests and confirm broker classes/contracts are absent**

Run: `cd web && bundle install && bin/rails test test/contracts/assistant_queue_contracts_test.rb test/services/assistant/turn_dispatcher_test.rb test/services/assistant/event_ingestor_test.rb`

Expected: FAIL on missing contract files/classes.

- [ ] **Step 3: Add closed JSON contracts and strict ingestion**

Each contract sets `additionalProperties: false`, string lengths, enums, array counts, and maximum content sizes. The event ingestor locks the turn, rejects correlation/profile mismatches and terminal-state replay, stores encrypted assistant messages/drafts, revokes the grant on terminal events, and records metadata audits without event bodies.

- [ ] **Step 4: Add least-privilege broker provisioning**

`provision_rabbitmq.rb` reads four password files, uses the management API only during provisioning, creates the vhost/topology, and applies regex permissions: Rails publishes `assistant.turns|assistant.validations` and consumes its two event queues; gateway consumes only its turn queue and publishes only `assistant.events`; validator consumes only its validation queue and publishes only `assistant.validation_events`; all configure permissions are empty after topology creation. Disable message tracing for the vhost and make every assistant queue/exchange non-durable.

- [ ] **Step 5: Add one dedicated Rails event-consumer process**

`Assistant::EventConsumer.run` consumes both Rails event queues with manual acknowledgements, a prefetch of 8, exact content-type checks, maximum body size, and idempotent correlation/event IDs. It rejects before acknowledge on malformed input, routes invalid input to no body-preserving dead-letter store, and logs only correlation/error codes.

- [ ] **Step 6: Run queue unit tests with no live broker**

Run: `cd web && bin/rails test test/contracts/assistant_queue_contracts_test.rb test/services/assistant/turn_dispatcher_test.rb test/services/assistant/event_ingestor_test.rb`

Expected: PASS using broker doubles.

- [ ] **Step 7: Conditionally commit after explicit authorization**

```bash
git add web/Gemfile web/Gemfile.lock assistant/contracts web/app/services/assistant web/test/contracts web/test/services/assistant ops/assistant/provision_rabbitmq.rb web/Procfile.dev web/Procfile.prod
git commit -m "Add isolated assistant queue contracts and ingestion."
```

### Task 10: Dedicated Go MCP broker with the fixed tool catalog

**Files:**
- Create: `assistant/mcp/go.mod`
- Create: `assistant/mcp/go.sum`
- Create: `assistant/mcp/cmd/hunter-mcp/main.go`
- Create: `assistant/mcp/internal/config/config.go`
- Create: `assistant/mcp/internal/auth/middleware.go`
- Create: `assistant/mcp/internal/hunter/client.go`
- Create: `assistant/mcp/internal/tools/catalog.go`
- Create: `assistant/mcp/internal/tools/handlers.go`
- Create: `assistant/mcp/internal/redact/checker.go`
- Create: `assistant/mcp/internal/limits/budget.go`
- Create: `assistant/mcp/internal/tools/handlers_test.go`
- Create: `assistant/mcp/internal/auth/middleware_test.go`
- Create: `assistant/mcp/internal/redact/checker_test.go`
- Create: `assistant/mcp/fuzz_test.go`
- Create: `assistant/mcp/Dockerfile`

**Interfaces:**
- Consumes: gateway bearer identity from `/run/secrets/assistant_gateway_mcp_token`, turn grant header, and Task 8 machine API.
- Produces: streamable HTTP MCP on internal port 8080 with exactly six tools and no resources/prompts/sampling/elicitation roots.
- Uses: `github.com/modelcontextprotocol/go-sdk v1.6.0`; configure cross-origin protection explicitly because this release does not enable it by default.

- [ ] **Step 1: Initialize the module with pinned dependencies and write the catalog test**

```go
func TestCatalogIsExactAndReadOnly(t *testing.T) {
    got := ToolNames(NewCatalog(fakeHunterClient{}))
    want := []string{"get_artifact_example", "get_authoring_policy", "get_selected_context", "get_validation_result", "validate_ansible_draft", "validate_whiterabbit_draft"}
    if !slices.Equal(want, got) { t.Fatalf("want %v, got %v", want, got) }
    for _, forbidden := range []string{"http", "shell", "search", "write", "execute", "filesystem"} {
        if slices.Contains(got, forbidden) { t.Fatalf("forbidden tool %q", forbidden) }
    }
}
```

- [ ] **Step 2: Run Go tests and verify missing implementation fails**

Run: `cd assistant/mcp && go test ./...`

Expected: FAIL on undefined catalog/types.

- [ ] **Step 3: Implement strict configuration and authentication**

Read the gateway token once from a mode-0400 file, reject empty/oversized values, compare SHA-256 digests in constant time, require JSON content type, restrict `Host` and `Origin`, cap request bodies, and attach the opaque grant to request context without logging it. Bind only `0.0.0.0:8080` on the internal Compose network; expose no host port.

- [ ] **Step 4: Implement typed closed-schema tools and double enforcement**

Every input struct uses explicit JSON fields and unknown-property rejection. Before a tool call, introspect the grant and verify the tool/resource locally; then call only the exact Rails machine route with MCP service identity plus the same grant. Measure Rails response bytes, apply a second 64 KiB cap, reject secret patterns, normalize errors, and never cache after grant expiry.

- [ ] **Step 5: Add protocol, malformed JSON, size, cancellation, and fuzz tests**

Test unknown methods/properties, wrong IDs, arbitrary URLs, recursive JSON, overlong strings, eight-call exhaustion, timeouts, cancellation, Rails redirect refusal, HTML response refusal, and token/body redaction. Run the official MCP conformance suite against protocol `2025-11-25` and save the command/version in `assistant/mcp/README.md`.

- [ ] **Step 6: Build a minimal non-root image and run tests**

The multi-stage Dockerfile builds with Go 1.25, runs from a distroless/static non-root stage at numeric UID/GID 65532, contains only the binary and CA bundle, has no shell/package manager, and declares an internal health check that returns status only.

Run: `cd assistant/mcp && go test -race ./... && go test -run=Fuzz -fuzz=FuzzToolInput -fuzztime=20s && docker build -t hunter-mcp:test .`

Expected: all tests PASS and image build succeeds.

- [ ] **Step 7: Conditionally commit after explicit authorization**

```bash
git add assistant/mcp
git commit -m "Add the fixed-catalog Go MCP broker."
```

### Task 11: Go LLM gateway, provider adapters, and allowlisted egress

**Files:**
- Create: `assistant/gateway/go.mod`
- Create: `assistant/gateway/go.sum`
- Create: `assistant/gateway/cmd/hunter-assistant-gateway/main.go`
- Create: `assistant/gateway/internal/config/config.go`
- Create: `assistant/gateway/internal/queue/consumer.go`
- Create: `assistant/gateway/internal/mcp/client.go`
- Create: `assistant/gateway/internal/provider/provider.go`
- Create: `assistant/gateway/internal/provider/openai.go`
- Create: `assistant/gateway/internal/provider/anthropic.go`
- Create: `assistant/gateway/internal/provider/envelope.go`
- Create: `assistant/gateway/internal/prompt/builder.go`
- Create: `assistant/gateway/internal/provider/contract_test.go`
- Create: `assistant/gateway/internal/provider/openai_test.go`
- Create: `assistant/gateway/internal/provider/anthropic_test.go`
- Create: `assistant/gateway/internal/prompt/builder_test.go`
- Create: `assistant/gateway/Dockerfile`
- Create: `assistant/egress/squid.conf`
- Create: `assistant/egress/Dockerfile`
- Create: `assistant/egress/test_proxy.sh`

**Interfaces:**
- Consumes: Task 9 turn jobs, MCP URL/token, provider secret files selected by a closed `secret_ref`, and a required HTTPS proxy.
- Produces: progress/final/error events to Task 9 and only two result envelopes: escaped assistant text or a typed draft envelope.
- Uses exact dependencies: OpenAI Go SDK 3.37.0, Anthropic Go SDK 1.61.0, MCP Go SDK 1.6.0, and `amqp091-go` 1.13.0.

- [ ] **Step 1: Write provider contract tests against local mock servers**

```go
func TestOpenAIRequestDisablesStorageAndHostedTools(t *testing.T) {
    req := capturedOpenAIRequest(t)
    if req.Store == nil || *req.Store { t.Fatal("store must be false") }
    if got := toolNames(req.Tools); !slices.Equal(got, fixedMCPTools) { t.Fatalf("tools=%v", got) }
    assertNoFields(t, req, "web_search", "computer_use", "file_search", "background")
}

func TestProviderNeverFallsBack(t *testing.T) {
    gateway := newGateway(failingOpenAI(), panicAnthropic())
    event := gateway.Handle(openAITurn())
    if event.Code != "provider_unavailable" { t.Fatalf("event=%+v", event) }
}
```

- [ ] **Step 2: Run tests and confirm adapters are absent**

Run: `cd assistant/gateway && go test ./...`

Expected: FAIL on undefined adapters.

- [ ] **Step 3: Implement fixed provider resolution and secret-file loading**

Resolve only the catalog snapshot's provider/model/secret reference; map `openai_primary` and `anthropic_primary` to exact mounted files. Reject unknown values, symlinks, non-regular files, empty/over-16-KiB files, redirects, non-HTTPS URLs, and missing proxy configuration. The host-side generation script sets source files to mode 0600; Compose mounts each secret only into its intended service, using mode 0400 where the Compose runtime supports it. The gateway contains fixed base URLs and ignores provider/proxy environment overrides except the single internal proxy address baked into Compose.

- [ ] **Step 4: Build untrusted-data prompts and schema-constrained responses**

System instructions describe drafting/no execution. User text and MCP results go into separately typed untrusted content blocks, never system/developer text. Enforce input/output token limits, eight tool calls, five-minute turn deadline, provider streaming byte cap, and closed assistant/draft envelopes. Reject partial streams, extra fields, unknown artifact types, HTML control characters, and model-asserted validation not backed by a validation tool result.

- [ ] **Step 5: Configure the egress proxy as the only Internet bridge**

Squid permits CONNECT only to port 443 for `api.openai.com` and `api.anthropic.com`; deny loopback, RFC1918, link-local, IPv6 local, and metadata ranges before the domain allow rule; deny plaintext methods, redirects at the gateway, oversized bodies, and invalid TLS. `assistant-egress` joins one internal gateway-facing network and one outbound-only network that contains no Hunter service. The gateway joins only the internal side and therefore cannot bypass the proxy.

- [ ] **Step 6: Run adapter, race, proxy, and image tests**

Run: `cd assistant/gateway && go test -race ./... && docker build -t hunter-assistant-gateway:test .`

Run: `docker build -t hunter-assistant-egress:test assistant/egress && assistant/egress/test_proxy.sh hunter-assistant-egress:test`

Expected: provider mocks PASS; approved hosts connect through a test TLS endpoint; HTTP, private IPs, metadata, arbitrary domains, and redirects fail.

- [ ] **Step 7: Conditionally commit after explicit authorization**

```bash
git add assistant/gateway assistant/egress
git commit -m "Add the isolated provider gateway and allowlisted egress."
```

### Task 12: Effect-free Whiterabbit draft validation

**Files:**
- Create: `web/app/services/assistant/authoring_policy.rb`
- Create: `web/app/services/assistant/draft_validation/whiterabbit.rb`
- Create: `web/app/services/assistant/draft_envelope.rb`
- Create: `web/test/services/assistant/draft_validation/whiterabbit_test.rb`
- Create: `web/test/services/assistant/authoring_policy_test.rb`
- Modify: `web/app/controllers/api/v1/assistant/machine/policies_controller.rb`
- Modify: `web/app/controllers/api/v1/assistant/machine/validations_controller.rb`

**Interfaces:**
- Produces: `Assistant::AuthoringPolicy.for("whiterabbit_template")` and `Assistant::DraftValidation::Whiterabbit.call(attributes) -> Result(valid?, codes, messages, normalized)`.
- Reuses: `ControlCenter::TemplateValidator.call`; does not persist a `ControlCenter::Template`.

- [ ] **Step 1: Write failing default-deny and non-persistence tests**

```ruby
test "assistant validation fails closed when command allowlist is empty" do
  stub_methods(ControlCenter::TemplateValidator, allowlist: -> { nil }) do
    result = Assistant::DraftValidation::Whiterabbit.call("name" => "probe", "kind" => "cmdscript", "commands" => [{ "command" => "httpx", "args" => [], "operator" => "" }])
    refute result.valid?
    assert_includes result.codes, "assistant_command_policy_unconfigured"
  end
end

test "validation never persists a template" do
  assert_no_difference -> { ControlCenter::Template.count } do
    Assistant::DraftValidation::Whiterabbit.call(
      "name" => "probe", "kind" => "cmdscript",
      "commands" => [{ "command" => "httpx", "args" => ["-silent"], "operator" => "" }]
    )
  end
end
```

- [ ] **Step 2: Run tests and verify the assistant validator is absent**

Run: `cd web && bin/rails test test/services/assistant/draft_validation/whiterabbit_test.rb test/services/assistant/authoring_policy_test.rb`

Expected: FAIL.

- [ ] **Step 3: Implement closed draft parsing and assistant-specific fail-closed policy**

Permit only template model fields and existing command structure; enforce model limits before calling `TemplateValidator`; require a non-empty allowlist; normalize errors to stable codes/locations without echoing arguments. Keep existing human Control Center behavior unchanged in this task, but final assistant save must call this stricter validator again.

- [ ] **Step 4: Expose versioned policy and dry-run validation through the machine API**

Policy returns schema version, max commands/args/lengths, operators, placeholders, and the configured command allowlist. Validation returns `valid`, normalized draft, `validation_version`, codes, and redacted messages. It cannot call create/update/send/job routes.

- [ ] **Step 5: Run focused and machine-route tests**

Run: `cd web && bin/rails test test/services/assistant/draft_validation/whiterabbit_test.rb test/services/assistant/authoring_policy_test.rb test/integration/api/v1/assistant/machine/tools_test.rb`

Expected: PASS.

- [ ] **Step 6: Conditionally commit after explicit authorization**

```bash
git add web/app/services/assistant/authoring_policy.rb web/app/services/assistant/draft_validation web/app/services/assistant/draft_envelope.rb web/app/controllers/api/v1/assistant/machine web/test/services/assistant
git commit -m "Add effect-free Whiterabbit draft validation."
```

### Task 13: Static Ansible policy and isolated syntax validator

**Files:**
- Create: `web/db/migrate/20260725010004_create_assistant_validation_requests.rb`
- Create: `web/app/models/assistant/validation_request.rb`
- Create: `web/app/services/assistant/draft_validation/ansible_static.rb`
- Create: `web/app/services/assistant/validation_dispatcher.rb`
- Create: `web/test/services/assistant/draft_validation/ansible_static_test.rb`
- Create: `web/test/services/assistant/validation_dispatcher_test.rb`
- Create: `assistant/validator/go.mod`
- Create: `assistant/validator/go.sum`
- Create: `assistant/validator/cmd/hunter-assistant-validator/main.go`
- Create: `assistant/validator/internal/worker/worker.go`
- Create: `assistant/validator/internal/check/check.go`
- Create: `assistant/validator/internal/check/check_test.go`
- Create: `assistant/validator/Dockerfile`
- Create: `assistant/validator/ansible.cfg`
- Modify: `web/app/controllers/api/v1/assistant/machine/validations_controller.rb`

**Interfaces:**
- Produces: `Assistant::DraftValidation::AnsibleStatic.call(yaml) -> Result`; default-deny deployment module allowlist.
- Produces: `Assistant::ValidationDispatcher.call(turn:, grant:, yaml:) -> validation_id` and asynchronous validation status `pending|valid|invalid|failed|expired`.
- Validator consumes source only, runs `ansible-playbook --syntax-check` in a fresh synthetic workspace, and returns normalized locations/codes only.
- Validator pins `github.com/rabbitmq/amqp091-go v1.13.0`; it has no Hunter HTTP client or token.

- [ ] **Step 1: Write failing static-policy tests for dangerous constructs and an empty module allowlist**

```ruby
test "assistant policy rejects execution and dependency-loading constructs" do
  %w[ansible.builtin.shell ansible.builtin.command ansible.builtin.raw ansible.builtin.script].each do |mod|
    result = Assistant::DraftValidation::AnsibleStatic.call("---\n- hosts: workers\n  tasks:\n    - #{mod}: whoami\n")
    refute result.valid?
    assert_includes result.codes, "ansible_module_not_allowed"
  end
end
```

- [ ] **Step 2: Run Rails tests and verify missing classes fail**

Run: `cd web && bin/rails test test/services/assistant/draft_validation/ansible_static_test.rb test/services/assistant/validation_dispatcher_test.rb`

Expected: FAIL.

- [ ] **Step 3: Implement static checks before queueing**

Reuse `ControlCenter::Ansible::PlaybookValidator`, then require a non-empty `ASSISTANT_ANSIBLE_MODULE_ALLOWLIST`. Reject modules outside it; all `roles`, `include*`, `import*`, `collections`, custom plugin paths, lookups, `vars_prompt`, local/delegated-local connection, environment credential injection, vault blocks, absolute paths, URLs in module names, anchors/aliases beyond existing YAML limits, and source over 64 KiB. Return codes/locations without source fragments.

- [ ] **Step 4: Add encrypted validation requests and non-durable dispatch**

Store encrypted YAML and encrypted normalized result, bind the request to turn/grant/draft, expire it with the grant, and publish source only to the validation queue. The browser and MCP can retrieve a result only through the current grant. Terminal ingestion deletes the encrypted source after recording its digest and result.

- [ ] **Step 5: Implement the validator worker with OS and Ansible isolation**

The worker rejects extra JSON fields, creates a mode-0700 directory under `/work`, writes only `playbook.yml`, sets `HOME` and Ansible temp paths inside it, disables inventory/plugins/roles/collections/callback loading, supplies `localhost,` only for syntax parsing while policy forbids local execution, invokes `ansible-playbook --syntax-check --inventory localhost, playbook.yml` with a 10-second deadline and process-group kill, caps stdout/stderr at 32 KiB, emits redacted codes, then removes the workspace. No command accepts user-controlled flags or filenames.

- [ ] **Step 6: Run Rails, Go, and adversarial validator tests**

Run: `cd web && bin/rails db:migrate && bin/rails test test/services/assistant/draft_validation/ansible_static_test.rb test/services/assistant/validation_dispatcher_test.rb`

Run: `cd assistant/validator && go test -race ./... && docker build -t hunter-assistant-validator:test .`

Expected: PASS; tests prove no execution, external role/plugin load, path escape, retained workspace, or unredacted stderr.

- [ ] **Step 7: Conditionally commit after explicit authorization**

```bash
git add web/db/migrate/20260725010004_create_assistant_validation_requests.rb web/db/schema.rb web/app/models/assistant/validation_request.rb web/app/services/assistant web/app/controllers/api/v1/assistant/machine web/test/services/assistant assistant/validator
git commit -m "Add isolated Ansible draft syntax validation."
```

### Task 14: End-to-end turn lifecycle, context disclosure, polling, and draft cards

**Files:**
- Create: `web/app/controllers/api/v1/assistant/turns_controller.rb`
- Create: `web/app/controllers/api/v1/assistant/drafts_controller.rb`
- Create: `web/app/services/assistant/turn_creator.rb`
- Create: `web/app/services/assistant/turn_canceler.rb`
- Create: `web/test/integration/api/v1/assistant/turns_test.rb`
- Create: `web/test/services/assistant/turn_creator_test.rb`
- Create: `web/test/javascript/assistant_controller_test.mjs`
- Modify: `web/config/routes.rb`
- Modify: `web/config/openapi/assistant.yaml`
- Modify: `web/app/views/layouts/_assistant.html.erb`
- Modify: `web/app/javascript/controllers/assistant_controller.js`
- Modify: `web/app/javascript/lib/assistant_api.js`

**Interfaces:**
- Produces: `POST conversations/:conversation_id/turns`, `GET turns/:id`, `POST turns/:id/cancel`, and `GET drafts/:id`.
- Produces: `Assistant::TurnCreator.call(conversation:, user:, body:, context_refs:) -> turn`; it persists before dispatch and returns no raw grant.
- UI renders polling state and validated draft cards; it never trusts model validation claims.

- [ ] **Step 1: Write failing lifecycle tests**

```ruby
test "turn creation resolves disclosure before issuing a one-use grant" do
  sign_in_as(users(:one))
  post "/api/v1/assistant/conversations/#{conversation.id}/turns", params: {
    message: "Draft a probe", contexts: [{ type: "target", id: target_id }]
  }, as: :json
  assert_response :accepted
  turn = Assistant::Turn.find(response.parsed_body["id"])
  assert_equal "queued", turn.status
  assert_equal [{ "type" => "target", "id" => target_id }], turn.turn_grant.resources
  refute_includes response.body, "turn_grant"
end
```

- [ ] **Step 2: Run Rails and JavaScript tests and verify failure**

Run: `cd web && bin/rails test test/integration/api/v1/assistant/turns_test.rb test/services/assistant/turn_creator_test.rb && node --test test/javascript/assistant_controller_test.mjs`

Expected: FAIL.

- [ ] **Step 3: Implement transactional create-before-dispatch and fail-closed errors**

Inside one transaction, lock the conversation, verify ownership/profile/settings, resolve at most ten selected records, persist user message/context/turn/audit, and issue a grant. Publish only after commit. If publish fails, mark interrupted, revoke the grant, and retain a stable retryable event. Retrying creates a new turn/grant; it never requeues the old raw grant.

- [ ] **Step 4: Add polling, cancellation, and safe draft rendering**

Poll at 750 ms while non-terminal and back off when the panel is closed. Cancellation revokes the grant and marks canceled; late events are rejected. Render message text and draft source with text nodes, show server validation state/version/errors, a sanitized diff, copy/open-editor controls, and `Save draft` only when current server validation is valid. Do not add run/send/schedule controls.

- [ ] **Step 5: Run lifecycle, DOM-safety, and API coverage tests**

Run: `cd web && bin/rails test test/integration/api/v1/assistant/turns_test.rb test/services/assistant/turn_creator_test.rb test/services/api_docs/coverage_test.rb && node --test test/javascript/assistant_controller_test.mjs`

Expected: PASS, including script/HTML/control-character fixtures rendered as text.

- [ ] **Step 6: Conditionally commit after explicit authorization**

```bash
git add web/app/controllers/api/v1/assistant web/app/services/assistant/turn_* web/test/integration/api/v1/assistant web/test/services/assistant web/test/javascript/assistant_controller_test.mjs web/config/routes.rb web/config/openapi/assistant.yaml web/app/views/layouts/_assistant.html.erb web/app/javascript
git commit -m "Connect assistant turns to safe draft review."
```

### Task 15: Shared Control Center persistence and confirmed assistant save

**Files:**
- Create: `web/db/migrate/20260725010005_add_lock_versions_to_authoring_artifacts.rb`
- Create: `web/app/services/control_center/templates/persist.rb`
- Create: `web/app/services/control_center/ansible/playbooks/persist.rb`
- Create: `web/app/services/assistant/confirmed_save.rb`
- Create: `web/app/controllers/api/v1/assistant/confirmed_saves_controller.rb`
- Create: `web/test/services/control_center/templates/persist_test.rb`
- Create: `web/test/services/control_center/ansible/playbooks/persist_test.rb`
- Create: `web/test/services/assistant/confirmed_save_test.rb`
- Create: `web/test/integration/api/v1/assistant/confirmed_saves_test.rb`
- Modify: `web/app/controllers/api/v1/control_center/templates_controller.rb`
- Modify: `web/app/controllers/api/v1/control_center/ansible/playbooks_controller.rb`
- Modify: `web/config/routes.rb`
- Modify: `web/config/openapi/assistant.yaml`

**Interfaces:**
- Produces: `ControlCenter::Templates::Persist.call(record:, attributes:, user:, expected_lock_version: nil)`.
- Produces: `ControlCenter::Ansible::Playbooks::Persist.call(record:, attributes:, user:, expected_lock_version: nil)`.
- Produces: `Assistant::ConfirmedSave.call(draft:, user:, destination:) -> Result(success?, record, errors)` and `POST /api/v1/assistant/drafts/:draft_id/confirmed_save`.

- [ ] **Step 1: Characterize existing controller persistence before refactoring**

Extend existing template/playbook integration tests to assert unchanged create/update validation, creator attribution, variable-set ordering, response envelopes, and bearer `control_center` behavior. Run them and require PASS before extracting services.

Run: `cd web && bin/rails test test/integration/api/v1/control_center/templates_test.rb test/integration/api/v1/control_center/ansible/playbooks_test.rb`

Expected: PASS.

- [ ] **Step 2: Write failing confirmed-save tests for CSRF, revalidation, ownership, stale destination, and no execution**

```ruby
test "save revalidates current policy and refuses a stale destination" do
  destination.update!(description: "changed elsewhere")
  result = Assistant::ConfirmedSave.call(draft: draft_with_old_lock, user: users(:one), destination: destination)
  refute result.success?
  assert_includes result.errors, "destination_stale"
end

test "save creates no job run or executor task" do
  assert_no_difference [-> { ControlCenter::Job.count }, -> { ControlCenter::Ansible::Run.count }, -> { ControlCenter::Ansible::ExecutorTask.count }] do
    Assistant::ConfirmedSave.call(draft: valid_draft, user: users(:one), destination: nil)
  end
end
```

- [ ] **Step 3: Extract and reuse domain persistence services**

Move controller transaction/parameter-independent persistence into the two services without changing public Control Center API behavior. Add `lock_version` to templates/playbooks. Services accept already-permitted hashes, assign creator on create, compare optional expected lock version inside a row lock, run existing model validation, and return a typed result rather than rendering.

- [ ] **Step 4: Implement a separate CSRF-protected save confirmation**

Require session-admin ownership of conversation/draft, valid terminal validation with the current validation version, full content/diff/destination confirmation, destination type/ID match, and current optimistic lock. Re-run Task 12 or Task 13 validation and then call the shared persistence service. Record target ID, artifact type, validation version, and SHA-256 hashes only. The assistant machine API, gateway, and MCP are absent from this call graph.

- [ ] **Step 5: Run migration, old API tests, and new save tests**

Run: `cd web && bin/rails db:migrate && bin/rails test test/services/control_center/templates/persist_test.rb test/services/control_center/ansible/playbooks/persist_test.rb test/services/assistant/confirmed_save_test.rb test/integration/api/v1/assistant/confirmed_saves_test.rb test/integration/api/v1/control_center/templates_test.rb test/integration/api/v1/control_center/ansible/playbooks_test.rb`

Expected: PASS with no job/executor records created.

- [ ] **Step 6: Conditionally commit after explicit authorization**

```bash
git add web/db/migrate/20260725010005_add_lock_versions_to_authoring_artifacts.rb web/db/schema.rb web/app/services/control_center web/app/services/assistant/confirmed_save.rb web/app/controllers/api/v1 web/test web/config/routes.rb web/config/openapi/assistant.yaml
git commit -m "Add revalidated human-confirmed assistant saves."
```

### Task 16: Retention, rate limits, kill switch, and audit enforcement

**Files:**
- Create: `web/app/services/assistant/retention.rb`
- Create: `web/app/services/assistant/rate_limiter.rb`
- Create: `web/app/services/assistant/kill_switch.rb`
- Create: `web/app/jobs/assistant/retention_job.rb`
- Create: `web/db/migrate/20260725010006_create_assistant_rate_limit_buckets.rb`
- Create: `web/app/models/assistant/rate_limit_bucket.rb`
- Create: `web/test/services/assistant/retention_test.rb`
- Create: `web/test/services/assistant/rate_limiter_test.rb`
- Create: `web/test/services/assistant/kill_switch_test.rb`
- Create: `web/test/jobs/assistant/retention_job_test.rb`
- Create: `web/test/models/assistant/rate_limit_bucket_test.rb`
- Modify: `web/config/recurring.yml`
- Modify: `web/app/controllers/api/v1/assistant/settings_controller.rb`

**Interfaces:**
- Produces: `Assistant::Retention.purge!(now:)`, `Assistant::RateLimiter.consume!(user:, action:, now:)`, and `Assistant::KillSwitch.disable!(user:)`.
- Kill switch atomically disables new dispatch, revokes every active grant, disables assistant service identities, interrupts non-terminal turns, and records metadata audits.

- [ ] **Step 1: Write failing boundary, deletion, rate, and kill-switch tests**

```ruby
test "kill switch revokes active authority without changing ordinary APIs" do
  Assistant::KillSwitch.disable!(user: users(:one))
  refute Assistant::Setting.instance.assistant_enabled?
  assert Assistant::TurnGrant.active.none?
  assert Assistant::ServiceIdentity.where(role: "mcp_reader", enabled: true).none?
  assert ApiToken.exists?
  assert Runner.exists?
end
```

- [ ] **Step 2: Run tests and confirm services are absent**

Run: `cd web && bin/rails test test/services/assistant/retention_test.rb test/services/assistant/rate_limiter_test.rb test/services/assistant/kill_switch_test.rb test/jobs/assistant/retention_job_test.rb`

Expected: FAIL.

- [ ] **Step 3: Implement retention and recurring cleanup**

Purge expired conversation content transactionally, then audit rows at their independent expiry; revoke expired grants and delete expired validation source/results. Configure `Assistant::RetentionJob` every hour in development and production. Immediate delete remains synchronous. Batch at 500 rows to bound locks and log counts only.

- [ ] **Step 4: Implement database-backed per-user limits and the kill switch**

Use Rails cache only as an optimization; persist atomic `(user_id, action, window_started_at, count)` buckets with a unique composite index so restarts do not reset the limit. Enforce 10 turn starts/minute, 60/hour, two concurrent turns, and one validation in flight per turn, all lowerable in configuration. The settings disable action invokes `Assistant::KillSwitch.disable!`; re-enable does not reactivate service identities or old grants and requires minting/enabling a reviewed identity.

- [ ] **Step 5: Run focused tests and recurring-schedule checks**

Run: `cd web && bin/rails db:migrate && bin/rails test test/services/assistant/retention_test.rb test/services/assistant/rate_limiter_test.rb test/services/assistant/kill_switch_test.rb test/jobs/assistant/retention_job_test.rb test/models/assistant/rate_limit_bucket_test.rb test/config/recurring_schedule_test.rb`

Expected: PASS.

- [ ] **Step 6: Conditionally commit after explicit authorization**

```bash
git add web/db/migrate/20260725010006_create_assistant_rate_limit_buckets.rb web/db/schema.rb web/app/models/assistant/rate_limit_bucket.rb web/app/services/assistant web/app/jobs/assistant web/test/services/assistant web/test/jobs/assistant web/test/models/assistant/rate_limit_bucket_test.rb web/config/recurring.yml web/app/controllers/api/v1/assistant/settings_controller.rb
git commit -m "Add assistant retention limits and emergency shutdown."
```

### Task 17: Compose secrets, networks, hardened services, and local integration

**Files:**
- Modify: `.gitignore`
- Modify: `docker-compose.yaml`
- Modify: `docker-compose.prod.yaml`
- Modify: `.env.example`
- Modify: `.gitea/workflows/build.yml`
- Create: `secrets/README.md`
- Create: `secrets/examples/openai_primary.example`
- Create: `secrets/examples/anthropic_primary.example`
- Create: `ops/assistant/generate_secrets.sh`
- Create: `ops/assistant/verify_compose_security.sh`
- Create: `ops/assistant/seccomp/gateway.json`
- Create: `ops/assistant/seccomp/mcp.json`
- Create: `ops/assistant/seccomp/validator.json`
- Create: `ops/assistant/seccomp/egress.json`
- Create: `ops/assistant/apparmor/hunter-assistant-gateway`
- Create: `ops/assistant/apparmor/hunter-mcp`
- Create: `ops/assistant/apparmor/hunter-assistant-validator`
- Create: `ops/assistant/apparmor/hunter-assistant-egress`
- Create: `web/test/config/assistant_compose_test.rb`

**Interfaces:**
- Produces dedicated services `assistant-gateway`, `hunter-mcp`, `assistant-validator`, `assistant-egress`, `assistant-events`, and one-shot `assistant-rabbitmq-init`, with no published host ports for assistant services.
- Produces isolated networks `assistant-queue`, `assistant-gateway-mcp`, `assistant-mcp-rails`, `assistant-validator-queue`, `assistant-egress-in` (internal), and `assistant-egress-out` (proxy only).
- Produces file secrets for provider keys, gateway-to-MCP token, MCP-to-Hunter token, and three RabbitMQ accounts.

- [ ] **Step 1: Write a failing Compose-security test**

```ruby
test "untrusted services have no ports privileges host mounts or unrelated networks" do
  config = YAML.safe_load(`docker compose config`)
  %w[assistant-gateway hunter-mcp assistant-validator assistant-egress].each do |name|
    service = config.fetch("services").fetch(name)
    assert_empty service.fetch("ports", [])
    assert_equal true, service["read_only"]
    assert_includes service.fetch("cap_drop"), "ALL"
    assert_includes service.fetch("security_opt"), "no-new-privileges:true"
    refute_equal "host", service["network_mode"]
    refute service.fetch("volumes", []).any? { |v| v.to_s.include?("docker.sock") }
  end
end
```

- [ ] **Step 2: Run the Compose test and verify assistant services are absent**

Run: `cd web && bin/rails test test/config/assistant_compose_test.rb`

Expected: FAIL.

- [ ] **Step 3: Add file-mounted secrets and generation workflow**

Ignore `secrets/dev/*` and `secrets/prod/*` while retaining example/README files. `generate_secrets.sh` creates mode-0600 random 32-byte values without displaying them, then instructs the operator to run the Rails token task and place its one-time MCP reader token in the named file. Compose mounts each secret only into the services listed in the approved credential matrix; Rails never mounts provider or gateway-to-MCP secrets, and gateway never mounts the MCP-to-Hunter token.

- [ ] **Step 4: Add least-connectivity service networks and no published ports**

Rails/`assistant-events` join only queue and MCP-Rails assistant networks in addition to their existing application network. Gateway joins queue, gateway-MCP, and egress-in. MCP joins gateway-MCP and MCP-Rails only. Validator joins validator-queue only. Egress joins egress-in and egress-out only. RabbitMQ joins queue/validator networks. No assistant service joins the database, Mongo, runner, executor, or target networks.

- [ ] **Step 5: Apply runtime hardening in both Compose files**

Set numeric non-root users, `read_only: true`, `cap_drop: [ALL]`, `no-new-privileges`, service-specific default-deny seccomp profiles, AppArmor profiles on supported Linux deployments, `init: true`, bounded `tmpfs` with `noexec,nosuid,nodev`, memory/CPU/PID limits, health checks with status-only output, and restart policies. Build each syscall allowlist from observed startup/contract-test calls, then prove forbidden `mount`, `ptrace`, `unshare`, `keyctl`, `bpf`, raw-socket, and unneeded socket-family operations are denied; the validator alone receives the exact process syscalls needed for its fixed Ansible subprocess. Add no host bind mount except read-only secret sources. Keep the feature disabled by default. Build/publish all new images in the existing Gitea workflow with immutable commit tags.

> **Correction (2026-07-26).** The `security_opt: apparmor=...` lines described
> here were never actually applied: they name custom profiles that must be
> loaded into the host kernel with `apparmor_parser` before `docker compose up`,
> and nothing in this stack did that, so a fresh host failed to start with
> `unable to apply apparmor profile: ... no such file or directory`. The four
> `apparmor=...` lines were removed from both compose files; the profile files
> themselves remain under `ops/assistant/apparmor/` (fixed and marked
> not-applied-by-default) for an operator who wants to load one manually.
> Docker's built-in `docker-default` AppArmor profile applies instead, layered
> over the seccomp profiles this step also describes, which are unaffected. See
> `docs/superpowers/specs/2026-07-26-hunter-assistant-zero-step-activation-delta.md`
> for the full reasoning and residual risk.

- [ ] **Step 6: Run resolved-Compose and service isolation checks**

Run: `docker compose config >/tmp/hunter-compose.resolved.yml && docker compose -f docker-compose.prod.yaml config >/tmp/hunter-compose-prod.resolved.yml`

Run: `cd web && bin/rails test test/config/assistant_compose_test.rb && ../ops/assistant/verify_compose_security.sh`

Expected: PASS; the script fails on a published port, root user, writable root, missing capability drop, broad network, Docker socket, absent limit, or a secret mounted to the wrong service.

- [ ] **Step 7: Start the disabled stack and verify health without provider calls**

Run: `docker compose up --build -d rabbitmq assistant-rabbitmq-init web assistant-events hunter-mcp assistant-gateway assistant-validator assistant-egress`

Run: `docker compose ps && docker compose logs --no-color --tail=100 hunter-mcp assistant-gateway assistant-validator assistant-events`

Expected: services are healthy/idle, no secret values appear in logs, and no provider request occurs while `ASSISTANT_ENABLED=false`.

- [ ] **Step 8: Conditionally commit after explicit authorization**

```bash
git add .gitignore docker-compose.yaml docker-compose.prod.yaml .env.example .gitea/workflows/build.yml secrets ops/assistant web/test/config/assistant_compose_test.rb
git commit -m "Harden and isolate the assistant Compose services."
```

### Task 18: Adversarial end-to-end verification and production security gate

**Files:**
- Create: `web/test/integration/assistant_end_to_end_test.rb`
- Create: `assistant/testdata/adversarial/provider_outputs.json`
- Create: `assistant/testdata/adversarial/tool_inputs.json`
- Create: `assistant/testdata/adversarial/selected_records.json`
- Create: `ops/assistant/test_network_denials.sh`
- Create: `ops/assistant/check_secret_leaks.sh`
- Create: `ops/assistant/rotation_drill.sh`
- Create: `docs/security/hunter-assistant-production-checklist.md`
- Modify: `.gitea/workflows/build.yml`
- Modify: `README.md`
- Modify: `AGENTS.md`

**Interfaces:**
- Produces a repeatable release gate covering Rails, JavaScript, Go, provider mocks, MCP conformance, container scanning, SBOMs, secret leakage, credential rotation, and network denial.
- Production checklist records reviewer, profile retention approval, exact image digests, scan artifacts, rotation date, and feature-enable decision; it contains no secret values.

- [ ] **Step 1: Add an end-to-end test with fake provider and broker boundaries**

The test signs in as the configured admin, selects one sanitized target, creates a pinned conversation/turn, captures the non-durable job, feeds a provider fixture that calls only allowed MCP tools, ingests a valid draft, confirms no record exists before review, performs CSRF confirmation, and asserts exactly one template/playbook is saved with no job/run/executor record.

- [ ] **Step 2: Add adversarial fixtures and negative assertions**

Cover injection pretending to be system/developer text, arbitrary IDs/URLs, unknown tools, enumeration, token requests, private keys, bearer values, oversized/deep JSON/YAML, HTML/script, terminal escapes, malformed Unicode, partial streams, deceptive validation, redirects, metadata IPs, write/send/schedule/execute requests, and provider fallback attempts. Each fixture must map to an expected stable refusal/error code.

- [ ] **Step 3: Add live network-denial checks from every container**

Verify gateway cannot reach Rails, Postgres, Mongo, executor, runner, RFC1918 targets, or metadata; MCP cannot reach provider/public Internet/databases/executors; validator cannot reach any address except RabbitMQ; Rails cannot resolve or connect directly to MCP's provider egress; egress rejects every non-provider destination. A denied path is a PASS only when both DNS and direct-IP attempts fail.

- [ ] **Step 4: Add supply-chain and secret-leak gates**

Generate CycloneDX/SPDX SBOMs for all new images, scan locked dependencies and images, run `bundle audit`, Brakeman, Go vulnerability checks, and repository/image secret scans. Fail CI on critical/high findings and any provider/service/grant token pattern in logs, layers, resolved Compose output, Git history, test artifacts, or SBOM metadata.

- [ ] **Step 5: Record the future-capability review rule in project context**

Add an Assistant section to `AGENTS.md` stating that a new context type, tool, provider feature, user role, write action, or execution action requires an approved threat-model delta, dedicated schema and authorization, UI disclosure, metadata audit coverage, adversarial tests, and explicit approval design. State that widening a generic tool or adding wildcard scope is prohibited.

- [ ] **Step 6: Execute the full local verification matrix**

Run: `cd web && bin/rails test`

Run: `cd web && node --test test/javascript/*.mjs`

Run: `cd assistant/mcp && go test -race ./...`

Run: `cd assistant/gateway && go test -race ./...`

Run: `cd assistant/validator && go test -race ./...`

Run: `ops/assistant/test_network_denials.sh && ops/assistant/check_secret_leaks.sh && ops/assistant/rotation_drill.sh`

Run: `cd web && bundle exec brakeman --no-pager && bundle exec bundle-audit check --update`

Expected: every command exits 0; no test uses a live provider key.

- [ ] **Step 7: Complete the external-review gate before enabling production**

Keep `ASSISTANT_ENABLED=false`. Provide the approved design, threat model, resolved production Compose, SBOMs, scan outputs, conformance output, denial-test output, and rotation drill to an independent reviewer. Record and remediate every critical/high issue, re-run the full matrix, pin production images by digest, confirm provider retention eligibility in each enabled profile, then explicitly record the enable decision. Enabling is an operator action after review and is not performed by this implementation plan.

- [ ] **Step 8: Conditionally commit after explicit authorization**

```bash
git add web/test/integration/assistant_end_to_end_test.rb assistant/testdata ops/assistant docs/security/hunter-assistant-production-checklist.md .gitea/workflows/build.yml README.md AGENTS.md
git commit -m "Add the assistant adversarial production security gate."
```

## Final Acceptance Criteria

- The global bubble appears only for the configured session administrator and all assistant browser mutations are CSRF-protected.
- Provider/model choice is pinned per conversation and the UI discloses the approved retention posture before the first turn.
- The browser never receives provider, service, RabbitMQ, or grant credentials.
- Rails persists before dispatch; every terminal path revokes the grant; retries mint a new grant.
- The gateway cannot reach Hunter; MCP is the only assistant service that can reach the sanitized machine API; Rails rechecks every grant.
- MCP lists exactly six tools and no generic/search/write/execution capability.
- Context output is field-allowlisted, bounded, versioned, secret-rejected, explicitly selected, and marked untrusted.
- Whiterabbit and Ansible draft validation is effect-free and fail-closed when deployment allowlists are absent.
- Ansible syntax checks use the isolated validator with no target credentials, user roles/plugins/collections, persistent workspace, or general network access.
- Generated content remains a draft until a separate current-session confirmation revalidates it and calls shared Control Center persistence.
- Encrypted transcripts obey 1–30 day retention and immediate deletion; 90-day default audits contain metadata only.
- Secrets are file-mounted to the minimum service set and absent from Git, images, process configuration output, logs, RabbitMQ tracing, and databases.
- Both Compose definitions enforce non-root/read-only/capability/resource/network restrictions and contain no external deployment-product dependency.
- Full Rails/JavaScript/Go suites, MCP conformance, adversarial fixtures, network denial, scans, SBOM, secret checks, and rotation drills pass.
- Production remains disabled until independent security review and remediation are documented.
