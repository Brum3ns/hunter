# Hunter Assistant Zero-Step Activation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install up to two provider API-key files, run `docker compose up`, and the
Assistant works — with a missing or empty key producing a self-explaining disabled
state in the chat rather than a boot failure.

**Architecture:** The approved broker architecture is unchanged — browser/Rails →
RabbitMQ → bounded Go gateway → fixed Go MCP broker → sanitized Rails machine API,
with the isolated validator and the Squid egress allowlist. This plan changes only
credential provisioning and the activation mechanism. The six internal machine
credentials move from operator-provisioned host files into a bootstrap-generated
volume; the two provider keys stay operator-provided host files; activation is
derived from provider-key validity instead of three manual steps.

**Tech Stack:** Ruby 3.3.6 / Rails 8 / Minitest, Go 1.25 (gateway, MCP, validator),
Docker Compose, RabbitMQ 4, Solid Queue.

## Global Constraints

- Ruby 3.3.6, Rails 8, Minitest. Minitest 6 dropped bundled mocks — use the
  `stub_methods` helper in `web/test/test_helper.rb`.
- Go 1.25; gateway, MCP and validator pin `github.com/rabbitmq/amqp091-go v1.13.0`.
- No secret value may reach stdout, stderr, a log, a test assertion, a document, an
  audit record, or a database column. Digests and stable reason codes only.
- No new Assistant context type, tool, provider feature, user role, write action, or
  execution action. The MCP catalog stays at exactly six tools. No generic network,
  search, shell, filesystem, credential, write, send, schedule or execution tool.
  Wildcard scopes remain prohibited.
- `docker-compose.yaml` and `docker-compose.prod.yaml` must stay identical except:
  image source (`build:` vs registry), `RAILS_ENV` + Procfile, published ports, and
  `RAILS_LOG_TO_STDOUT`. Hardening directives must match one-for-one.
- One code path for both Rails modes. No `Rails.env.production?` branching in
  assistant code.
- Never abort boot for a credential or configuration problem. Every such problem
  becomes a stable reason code surfaced in the chat.
- Rails tests need PostgreSQL at `172.17.0.1:5433`, database `hunter_test`. Load only
  `DB_USERNAME`/`DB_PASSWORD` from `../.env` without printing them. Mongo is doubled.
- Commit author `Claude <noreply@anthropic.com>`; single-sentence commit messages;
  commit only when the operator asks.
- Docker is unavailable in the implementation environment. Container-level
  acceptance runs on the operator's host and is recorded in Task 9.

---

## File Structure

**Created:**

| File | Responsibility |
|---|---|
| `web/app/services/assistant/provider_credentials.rb` | Classify each provider key file into one stable reason code. No file contents ever returned. |
| `web/app/services/assistant/activation.rb` | Derive activation state from credential validity, the ENV kill override, and the admin setting. |
| `ops/assistant/bootstrap.sh` | One-shot: generate the five random machine credentials into the secrets volume, create-only. |
| `ops/assistant/bootstrap_service_token.rb` | Mint the MCP→Hunter `ServiceIdentity` and write the raw value straight to file, never printing it. |
| `web/test/services/assistant/provider_credentials_test.rb` | Adversarial credential matrix. |
| `web/test/services/assistant/activation_test.rb` | Derivation, override precedence, audit emission. |
| `web/test/config/assistant_bootstrap_test.rb` | Bootstrap idempotence and silence. |
| `web/test/contracts/assistant_secret_paths_test.rb` | Rails, Go and Compose agree on every secret path. |

**Modified:**

| File | Change |
|---|---|
| `web/app/services/assistant/config.rb:17-19` | `enabled?` becomes derived; `ASSISTANT_ENABLED=false` becomes a kill override. |
| `web/app/services/assistant/config.rb:66-80` | `validate_production!` returns reason codes instead of raising. |
| `web/config/initializers/assistant.rb:2` | Drop the `Rails.env.production?` branch; run one preflight in both modes. |
| `web/app/controllers/api/v1/assistant/base_controller.rb:111-121` | `serialize_setting` gains `providers` and `disabled_reason`. |
| `web/app/models/assistant/setting.rb:11-15` | Singleton defaults to enabled unless explicitly disabled by an admin. |
| `web/config/assistant_provider_catalog.yml` | Each entry gains `secret_file`. |
| `web/app/javascript/controllers/assistant_controller.js` | Render the disabled notice, text-only. |
| `assistant/gateway/internal/config/config.go:41-45` | Machine credentials read from the volume path. |
| `assistant/mcp/internal/config/config.go` | Same. |
| `assistant/validator/internal/config/*.go` | Same. |
| `ops/assistant/generate_secrets.sh` | Drop the `dev\|prod` argument; single `secrets/` directory. |
| `docker-compose.yaml`, `docker-compose.prod.yaml` | Drop `profiles:`, add `assistant-bootstrap`, add the secrets volume, single secret directory. |
| `secrets/README.md`, both runbooks, production checklist, checkpoint doc | Documentation. |

**Deleted:** `secrets/dev/`, `secrets/prod/`, `secrets/disabled/` (replaced by a single
gitignored `secrets/` directory).

**Path contract locked here and asserted by Task 8:**

- Operator-provided provider keys: `/run/secrets/assistant_openai_api_key`,
  `/run/secrets/assistant_anthropic_api_key`, reached by a **read-only bind mount of
  `./secrets` at `/run/secrets`** on `assistant-gateway` only. A bind mount is used
  instead of a Compose file-backed secret because Compose refuses to start when a
  file-backed secret source is missing, and an absent key file must be a normal
  disabled state, not a boot failure. `secrets/.keep` is tracked so the directory
  always exists.
- **No file-backed Compose secret may remain in either compose file.** A missing file
  must never be able to block startup.
- Bootstrap-generated machine credentials: `/run/assistant/secrets/<name>`, mode
  `0400`, owner `1000:1000`, on the `assistant_secrets` volume, mounted read-only by
  consumers: `assistant_rails_amqp_password`, `assistant_gateway_amqp_password`,
  `assistant_validator_amqp_password`, `assistant_rabbitmq_provision_password`,
  `assistant_gateway_mcp_token`, `assistant_mcp_hunter_token`.

---

### Task 1: Threat-model delta finalisation

**Files:**
- Modify: `docs/superpowers/specs/2026-07-26-hunter-assistant-zero-step-activation-delta.md`

No code. Rewrite the delta to the operator's confirmed specification so the approved
document matches what Tasks 2–9 build.

- [ ] **Step 1: Replace the "Change 2" section**

Activation is derived from provider-key validity alone. Delete the in-repo catalog
approval requirement (`approved:`, `approved_by:`, `approved_on:`) — the operator
rejected it. Record instead:

- Retention posture stays **disclosed** in the chat before the first turn; it is not
  a blocking gate.
- The admin off-switch in Settings is retained as a runtime kill switch.
- `ASSISTANT_ENABLED` is repurposed from an opt-in to a kill override: unset means
  derived, `false` means forced off.
- Accepted risk, verbatim: possession of a valid provider key file on the host is
  treated as the operator's intent to enable that provider. A restored backup or a
  copied secrets directory activates provider egress. Compensating controls are the
  retained kill switch, mandatory activation auditing, and the startup log line.

- [ ] **Step 2: Replace the "one codebase" statement**

State that there is no dev/prod code variant: the compose files differ only in image
source, `RAILS_ENV`/Procfile, published ports and `RAILS_LOG_TO_STDOUT`, and that
`secrets/{dev,prod,disabled}` collapses to a single `secrets/` directory.

- [ ] **Step 3: Record approval**

Set `Operator approval: APPROVED 2026-07-26` and status `APPROVED`.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-07-26-hunter-assistant-zero-step-activation-delta.md
git commit -m "Record the approved zero-step Assistant activation threat-model delta."
```

---

### Task 2: Single secrets directory

**Files:**
- Delete: `secrets/dev/`, `secrets/prod/`, `secrets/disabled/`
- Modify: `.gitignore:33-37`, `ops/assistant/generate_secrets.sh`, `secrets/README.md`
- Test: `web/test/config/assistant_compose_test.rb`

**Interfaces:**
- Produces: host secret directory `./secrets/`, containing only operator-provided
  provider keys plus `.keep`, `README.md` and `examples/`.

- [ ] **Step 1: Write the failing test**

Add to `web/test/config/assistant_compose_test.rb`:

```ruby
def test_both_compose_files_read_provider_keys_from_the_single_secret_directory
  %w[docker-compose.yaml docker-compose.prod.yaml].each do |name|
    body = ROOT.join(name).read

    assert_includes body, "- ./secrets:/run/secrets:ro",
      "#{name} does not bind-mount the secret directory read-only"
    refute_match(/secrets\/(dev|prod)\b/, body,
      "#{name} still references a per-environment secret directory")
    refute_match(/^  assistant_(openai|anthropic)_api_key:/m, body,
      "#{name} still defines a provider key as a file-backed Compose secret")
  end
end

def test_git_ignores_secret_material_but_keeps_documentation
  ignored = ROOT.join(".gitignore").read

  assert_includes ignored, "/secrets/*"
  assert_includes ignored, "!/secrets/.keep"
  assert_includes ignored, "!/secrets/README.md"
  assert_includes ignored, "!/secrets/examples/"
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd web && ruby -Itest test/config/assistant_compose_test.rb -n "/single_secret_directory|ignores_secret_material/"`
Expected: FAIL — both files still use `${ASSISTANT_SECRET_DIR:-./secrets/disabled}`.

- [ ] **Step 3: Implement**

In `.gitignore`, replace lines 33–37 with:

```gitignore
# Assistant secrets. Only documentation and inert examples are tracked.
/secrets/*
!/secrets/.keep
!/secrets/README.md
!/secrets/examples/
```

In both compose files, delete **only** the two provider-key entries
(`assistant_openai_api_key`, `assistant_anthropic_api_key`) from the top-level
`secrets:` block, and delete the `secrets:` mounts that referenced them on
`assistant-gateway`. Replace that access with a read-only bind mount, so a missing
file is readable-as-absent rather than fatal:

```yaml
  assistant-gateway:
    volumes:
      - ./secrets:/run/secrets:ro
```

**Scope limit — every intermediate commit must still boot.** Leave the other six
machine-credential secret definitions, their `${ASSISTANT_SECRET_DIR:-./secrets/disabled}`
sources, their service mounts, `ASSISTANT_SECRET_DIR` in `.env.example`, and the
`secrets/disabled/` directory exactly as they are. Task 9 moves those to the volume and
removes them together.

Why this matters: `ops/assistant/rabbitmq/entrypoint.sh` exits 1 with "RabbitMQ
provisioning credential unavailable" when its secret file is absent, and Compose aborts
when a file-backed secret's source file is missing. Removing those six mounts or deleting
`secrets/disabled/` before the volume exists would make `docker compose up` fail between
this task and Task 9.

Delete only `secrets/dev/` and `secrets/prod/`, which are now empty.

The gateway's existing `safeSecretMode` check still enforces mode `0400`/`0600`, and
a bind mount preserves host ownership, so the mode and owner guarantees are unchanged.

Rewrite `ops/assistant/generate_secrets.sh` as `ops/assistant/prepare_secrets.sh`,
dropping the `dev|prod` argument. Its only remaining job is operator convenience on
the host: create `secrets/` at `0700` and, if absent, create the two provider key
files as empty `0600` files so `docker compose up` has the file-backed secrets it
requires. It no longer generates machine credentials — Task 3 does that.

```sh
#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=${HUNTER_ASSISTANT_REPOSITORY_ROOT:-$(CDPATH= cd -- "$script_dir/../.." && pwd)}
secret_dir="$repository_root/secrets"

umask 077
mkdir -p "$secret_dir"
chmod 0700 "$secret_dir"

echo "secrets/ is ready. Create assistant_openai_api_key and/or"
echo "assistant_anthropic_api_key at mode 0600 to enable a provider."
echo "An absent or empty file keeps that provider disabled; the chat reports why."
```

The script deliberately does **not** create empty key files. An absent file is a
supported disabled state, so there is nothing to pre-create.

Delete `secrets/dev/`, `secrets/prod/` and `secrets/disabled/`, keeping
`secrets/.keep`, `secrets/README.md` and `secrets/examples/`.

- [ ] **Step 4: Run to verify it passes**

Run: `cd web && ruby -Itest test/config/assistant_compose_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add .gitignore docker-compose.yaml docker-compose.prod.yaml .env.example \
        ops/assistant/prepare_secrets.sh secrets web/test/config/assistant_compose_test.rb
git rm -r --cached secrets/dev secrets/prod secrets/disabled 2>/dev/null || true
git commit -m "Collapse the Assistant secret directories into a single gitignored location."
```

---

### Task 3: Bootstrap-generated machine credentials

**Files:**
- Create: `ops/assistant/bootstrap.sh`, `ops/assistant/bootstrap_service_token.rb`
- Test: `web/test/config/assistant_bootstrap_test.rb`,
  `web/test/lib/tasks/assistant_service_tokens_test.rb` (extend)

**Interfaces:**
- Produces: six files under `/run/assistant/secrets/`, mode `0400`, owner
  `1000:1000`. `bootstrap_service_token.rb` mints exactly one enabled `mcp_reader`
  `Assistant::ServiceIdentity` and writes its raw token to
  `/run/assistant/secrets/assistant_mcp_hunter_token`, returning nothing on stdout.

- [ ] **Step 1: Write the failing test**

```ruby
require "minitest/autorun"
require "open3"
require "pathname"
require "tmpdir"

class AssistantBootstrapTest < Minitest::Test
  ROOT = Pathname.new(__dir__).join("../../..").expand_path.freeze
  SCRIPT = ROOT.join("ops/assistant/bootstrap.sh").freeze
  GENERATED = %w[
    assistant_rabbitmq_provision_password
    assistant_rails_amqp_password
    assistant_gateway_amqp_password
    assistant_validator_amqp_password
    assistant_gateway_mcp_token
  ].freeze

  def test_generates_every_machine_credential_at_mode_0400
    Dir.mktmpdir do |dir|
      stdout, stderr, status = run_bootstrap(dir)

      assert status.success?, "bootstrap failed: #{stderr}"
      GENERATED.each do |name|
        path = Pathname.new(dir).join(name)
        assert_path_exists path, "#{name} was not generated"
        assert_equal "0400", (path.stat.mode & 0o777).to_s(8), "#{name} has the wrong mode"
        refute_empty path.read.strip, "#{name} is empty"
      end
      assert_empty stdout.strip, "bootstrap printed to stdout"
    end
  end

  def test_never_prints_a_generated_value
    Dir.mktmpdir do |dir|
      run_bootstrap(dir)
      values = GENERATED.map { |name| Pathname.new(dir).join(name).read.strip }
      stdout, stderr, _status = run_bootstrap(dir)

      values.each do |value|
        refute_includes stdout, value, "a secret value reached stdout"
        refute_includes stderr, value, "a secret value reached stderr"
      end
    end
  end

  def test_is_idempotent_and_never_rewrites_an_existing_secret
    Dir.mktmpdir do |dir|
      run_bootstrap(dir)
      before = GENERATED.to_h { |name| [ name, Pathname.new(dir).join(name).read ] }

      _stdout, stderr, status = run_bootstrap(dir)

      assert status.success?, "second run failed: #{stderr}"
      before.each do |name, value|
        assert_equal value, Pathname.new(dir).join(name).read, "#{name} was rewritten"
      end
    end
  end

  private

  def run_bootstrap(dir)
    Open3.capture3({ "ASSISTANT_SECRET_TARGET" => dir }, "sh", SCRIPT.to_s)
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd web && ruby -Itest test/config/assistant_bootstrap_test.rb`
Expected: FAIL — `ops/assistant/bootstrap.sh` does not exist.

- [ ] **Step 3: Implement `ops/assistant/bootstrap.sh`**

```sh
#!/bin/sh
set -eu

target=${ASSISTANT_SECRET_TARGET:-/run/assistant/secrets}
umask 077
mkdir -p "$target"

generate() {
  path="$target/$1"
  [ -e "$path" ] && return 0

  temporary=$(mktemp "$target/.bootstrap.XXXXXX")
  openssl rand -base64 32 | tr -d '\n' > "$temporary"
  chmod 0400 "$temporary"
  if ! ln "$temporary" "$path" 2>/dev/null; then
    rm -f "$temporary"
    return 0
  fi
  rm -f "$temporary"
}

generate assistant_rabbitmq_provision_password
generate assistant_rails_amqp_password
generate assistant_gateway_amqp_password
generate assistant_validator_amqp_password
generate assistant_gateway_mcp_token
```

Note the create-only contract: an existing file is never read, rewritten, or logged,
and a lost `ln` race is a success, not an error.

- [ ] **Step 4: Run to verify it passes**

Run: `cd web && ruby -Itest test/config/assistant_bootstrap_test.rb`
Expected: PASS, 3 runs.

- [ ] **Step 5: Write the failing service-token test**

Add to `web/test/lib/tasks/assistant_service_tokens_test.rb`:

```ruby
def test_bootstrap_writes_the_mcp_token_to_file_without_printing_it
  Dir.mktmpdir do |dir|
    path = Pathname.new(dir).join("assistant_mcp_hunter_token")
    output = capture_io do
      Assistant::BootstrapServiceToken.call(path: path)
    end.join

    assert_path_exists path
    assert_equal "0400", (path.stat.mode & 0o777).to_s(8)
    refute_includes output, path.read.strip, "the raw token was printed"
    assert_equal 1, Assistant::ServiceIdentity.where(enabled: true, role: "mcp_reader").count
  end
end

def test_bootstrap_service_token_is_idempotent
  Dir.mktmpdir do |dir|
    path = Pathname.new(dir).join("assistant_mcp_hunter_token")
    Assistant::BootstrapServiceToken.call(path: path)
    first = path.read

    Assistant::BootstrapServiceToken.call(path: path)

    assert_equal first, path.read, "an existing token file was rewritten"
    assert_equal 1, Assistant::ServiceIdentity.where(enabled: true, role: "mcp_reader").count
  end
end
```

- [ ] **Step 6: Run to verify it fails**

Run: `cd web && bin/rails test test/lib/tasks/assistant_service_tokens_test.rb`
Expected: FAIL — `Assistant::BootstrapServiceToken` is undefined.

- [ ] **Step 7: Implement `web/app/services/assistant/bootstrap_service_token.rb`**

```ruby
module Assistant
  module BootstrapServiceToken
    IDENTITY_NAME = "hunter-mcp".freeze

    module_function

    # Mints the MCP reader identity and writes the raw token straight to disk.
    # The raw value is never returned, logged, or printed.
    def call(path:)
      path = Pathname.new(path)
      return if path.exist?

      identity = nil
      raw = nil
      ServiceIdentity.transaction do
        ServiceIdentity.where(enabled: true, role: "mcp_reader").find_each do |existing|
          existing.update!(enabled: false, rotated_at: Time.current)
        end
        identity, raw = ServiceIdentity.generate!(name: IDENTITY_NAME, role: "mcp_reader")
      end

      write_once(path, raw)
      identity
    ensure
      raw = nil
    end

    def write_once(path, raw)
      path.dirname.mkpath
      temporary = path.dirname.join(".#{path.basename}.#{Process.pid}")
      temporary.write(raw)
      temporary.chmod(0o400)
      begin
        File.link(temporary.to_s, path.to_s)
      rescue Errno::EEXIST
        nil
      ensure
        temporary.unlink
      end
    end
    private_class_method :write_once
  end
end
```

Add `ops/assistant/bootstrap_service_token.rb` as the container entrypoint shim:

```ruby
require_relative "../../web/config/environment"

Assistant::BootstrapServiceToken.call(
  path: ENV.fetch("ASSISTANT_MCP_TOKEN_PATH", "/run/assistant/secrets/assistant_mcp_hunter_token")
)
```

- [ ] **Step 8: Run to verify it passes**

Run: `cd web && bin/rails test test/lib/tasks/assistant_service_tokens_test.rb`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add ops/assistant/bootstrap.sh ops/assistant/bootstrap_service_token.rb \
        web/app/services/assistant/bootstrap_service_token.rb \
        web/test/config/assistant_bootstrap_test.rb \
        web/test/lib/tasks/assistant_service_tokens_test.rb
git commit -m "Generate Assistant machine credentials and the MCP token on first boot."
```

---

### Task 4: Provider credential preflight

**Files:**
- Create: `web/app/services/assistant/provider_credentials.rb`
- Modify: `web/config/assistant_provider_catalog.yml`,
  `web/app/services/assistant/provider_catalog.rb`
- Test: `web/test/services/assistant/provider_credentials_test.rb`

**Interfaces:**
- Produces: `Assistant::ProviderCredentials.status(entry)` returning
  `Status = Data.define(:slug, :reason, :available)`; `.statuses` returning one per
  catalog entry; `.available_slugs`. `reason` is one of `valid`, `absent`, `empty`,
  `placeholder`, `oversize`, `bad_mode`, `symlink`, `unreadable`. File contents are
  never returned or logged.
- Consumes: `Assistant::ProviderCatalog.entries` (Task 4 adds `secret_file`).

- [ ] **Step 1: Write the failing test**

```ruby
require "test_helper"
require "tmpdir"

class Assistant::ProviderCredentialsTest < ActiveSupport::TestCase
  def test_a_populated_key_file_is_valid
    with_secret("sk-live-value", mode: 0o400) do |dir|
      assert_equal "valid", status(dir).reason
      assert_predicate status(dir), :available
    end
  end

  def test_an_empty_file_is_disabled_without_being_an_error
    with_secret("", mode: 0o400) do |dir|
      assert_equal "empty", status(dir).reason
      refute_predicate status(dir), :available
    end
  end

  def test_a_whitespace_only_file_is_treated_as_empty
    with_secret("   \n", mode: 0o400) do |dir|
      assert_equal "empty", status(dir).reason
    end
  end

  def test_the_checked_in_placeholder_is_rejected
    with_secret("replace_with_openai_api_key", mode: 0o400) do |dir|
      assert_equal "placeholder", status(dir).reason
    end
  end

  def test_a_missing_file_is_absent
    Dir.mktmpdir { |dir| assert_equal "absent", status(dir).reason }
  end

  def test_a_world_readable_file_is_rejected
    with_secret("sk-live-value", mode: 0o644) do |dir|
      assert_equal "bad_mode", status(dir).reason
    end
  end

  def test_a_symlinked_secret_is_rejected
    Dir.mktmpdir do |dir|
      real = Pathname.new(dir).join("real")
      real.write("sk-live-value")
      real.chmod(0o400)
      File.symlink(real.to_s, Pathname.new(dir).join("assistant_openai_api_key").to_s)

      assert_equal "symlink", status(dir).reason
    end
  end

  def test_an_oversize_file_is_rejected
    with_secret("x" * 8_193, mode: 0o400) do |dir|
      assert_equal "oversize", status(dir).reason
    end
  end

  def test_no_reason_code_leaks_the_secret_value
    with_secret("sk-live-canary", mode: 0o400) do |dir|
      refute_includes status(dir).inspect, "sk-live-canary"
    end
  end

  private

  def entry
    Assistant::ProviderCatalog.fetch!("openai_primary")
  end

  def status(dir)
    Assistant::ProviderCredentials.status(entry, directory: dir)
  end

  def with_secret(body, mode:)
    Dir.mktmpdir do |dir|
      path = Pathname.new(dir).join("assistant_openai_api_key")
      path.write(body)
      path.chmod(mode)
      yield dir
    end
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd web && bin/rails test test/services/assistant/provider_credentials_test.rb`
Expected: FAIL — `Assistant::ProviderCredentials` is undefined.

- [ ] **Step 3: Add `secret_file` to the catalog**

`web/config/assistant_provider_catalog.yml`:

```yaml
openai_primary:
  provider: openai
  model: gpt-5
  secret_ref: openai_primary
  secret_file: assistant_openai_api_key
  input_limit: 32768
  output_limit: 8192
  retention_posture: standard

anthropic_primary:
  provider: anthropic
  model: claude-sonnet-5
  secret_ref: anthropic_primary
  secret_file: assistant_anthropic_api_key
  input_limit: 32768
  output_limit: 8192
  retention_posture: standard
```

Add `:secret_file` to the `Entry` `Data.define` list and to `load_entries` via
`attributes.fetch("secret_file")`.

- [ ] **Step 4: Implement `provider_credentials.rb`**

```ruby
module Assistant
  # Classifies each provider key file into one stable reason code. A file's
  # contents never leave this module: only a reason code is returned.
  module ProviderCredentials
    Status = Data.define(:slug, :reason, :available)

    DEFAULT_DIRECTORY = "/run/secrets".freeze
    MAX_BYTES = 8192
    ACCEPTED_MODES = [ 0o400, 0o600 ].freeze
    PLACEHOLDER = /\Areplace_with_/i

    module_function

    def statuses(directory: DEFAULT_DIRECTORY)
      ProviderCatalog.entries.values.map { |entry| status(entry, directory: directory) }
    end

    def available_slugs(directory: DEFAULT_DIRECTORY)
      statuses(directory: directory).select(&:available).map(&:slug)
    end

    def status(entry, directory: DEFAULT_DIRECTORY)
      Status.new(slug: entry.slug, reason: reason_for(entry, directory), available: false)
        .then { |status| status.with(available: status.reason == "valid") }
    end

    def reason_for(entry, directory)
      path = Pathname.new(directory).join(entry.secret_file)

      begin
        info = path.lstat
      rescue Errno::ENOENT
        return "absent"
      rescue SystemCallError
        return "unreadable"
      end

      return "symlink" if info.symlink?
      return "oversize" if info.size > MAX_BYTES
      return "bad_mode" unless ACCEPTED_MODES.include?(info.mode & 0o777)

      body = begin
        path.read(MAX_BYTES).to_s
      rescue SystemCallError
        return "unreadable"
      end

      return "empty" if body.strip.empty?
      return "placeholder" if body.strip.match?(PLACEHOLDER)

      "valid"
    end
    private_class_method :reason_for
  end
end
```

- [ ] **Step 5: Run to verify it passes**

Run: `cd web && bin/rails test test/services/assistant/provider_credentials_test.rb`
Expected: PASS, 9 runs.

- [ ] **Step 6: Commit**

```bash
git add web/app/services/assistant/provider_credentials.rb \
        web/app/services/assistant/provider_catalog.rb \
        web/config/assistant_provider_catalog.yml \
        web/test/services/assistant/provider_credentials_test.rb
git commit -m "Classify Assistant provider credentials into stable reason codes."
```

---

### Task 5: Derived activation and audit

**Files:**
- Create: `web/app/services/assistant/activation.rb`
- Modify: `web/app/services/assistant/config.rb:17-19`,
  `web/app/models/assistant/setting.rb:11-15`
- Test: `web/test/services/assistant/activation_test.rb`

**Interfaces:**
- Produces: `Assistant::Activation.state(directory:)` returning
  `State = Data.define(:active, :available_slugs, :reason)`.
  `Assistant::Config.enabled?` delegates to it.
- Precedence: `ASSISTANT_ENABLED=false` forces off; otherwise at least one `valid`
  provider activates. The admin's explicit disable (`disabled_at` present) still
  wins over derivation.

- [ ] **Step 1: Write the failing test**

```ruby
require "test_helper"
require "tmpdir"

class Assistant::ActivationTest < ActiveSupport::TestCase
  def test_a_valid_provider_key_activates_the_assistant
    with_keys("assistant_anthropic_api_key" => "sk-live") do |dir|
      state = Assistant::Activation.state(directory: dir)

      assert_predicate state, :active
      assert_equal [ "anthropic_primary" ], state.available_slugs
    end
  end

  def test_empty_keys_leave_the_assistant_inactive_with_a_reason
    with_keys("assistant_anthropic_api_key" => "", "assistant_openai_api_key" => "") do |dir|
      state = Assistant::Activation.state(directory: dir)

      refute_predicate state, :active
      assert_equal "no_provider_credentials", state.reason
      assert_empty state.available_slugs
    end
  end

  def test_the_environment_kill_override_forces_the_assistant_off
    with_keys("assistant_anthropic_api_key" => "sk-live") do |dir|
      stub_methods(Assistant::Config, configured: ->(key) { key == "ASSISTANT_ENABLED" ? "false" : nil }) do
        state = Assistant::Activation.state(directory: dir)

        refute_predicate state, :active
        assert_equal "disabled_by_environment", state.reason
      end
    end
  end

  def test_an_administrator_disable_survives_a_valid_key
    Assistant::Setting.instance.disable!(user: users(:one))

    with_keys("assistant_anthropic_api_key" => "sk-live") do |dir|
      refute Assistant::Config.enabled?(directory: dir) && Assistant::Setting.instance.assistant_enabled?
    end
  end

  def test_a_new_singleton_defaults_to_enabled
    Assistant::Setting.delete_all

    assert_predicate Assistant::Setting.instance, :assistant_enabled?
  end

  def test_activation_audit_carries_no_secret_material
    with_keys("assistant_anthropic_api_key" => "sk-live-canary") do |dir|
      event = Assistant::Activation.audit_payload(Assistant::Activation.state(directory: dir))

      refute_includes event.to_json, "sk-live-canary"
      assert_equal [ "anthropic_primary" ], event[:available_slugs]
    end
  end

  private

  def with_keys(files)
    Dir.mktmpdir do |dir|
      files.each do |name, body|
        path = Pathname.new(dir).join(name)
        path.write(body)
        path.chmod(0o400)
      end
      yield dir
    end
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd web && bin/rails test test/services/assistant/activation_test.rb`
Expected: FAIL — `Assistant::Activation` is undefined.

- [ ] **Step 3: Implement `activation.rb`**

```ruby
module Assistant
  # Activation is derived: a valid provider key file means that provider is on.
  # ASSISTANT_ENABLED is a kill override only, never an opt-in.
  module Activation
    State = Data.define(:active, :available_slugs, :reason)

    module_function

    def state(directory: ProviderCredentials::DEFAULT_DIRECTORY)
      return State.new(active: false, available_slugs: [], reason: "disabled_by_environment") if killed?

      slugs = ProviderCredentials.available_slugs(directory: directory)
      if slugs.empty?
        State.new(active: false, available_slugs: [], reason: "no_provider_credentials")
      else
        State.new(active: true, available_slugs: slugs, reason: "active")
      end
    end

    def audit_payload(state)
      { active: state.active, reason: state.reason, available_slugs: state.available_slugs }
    end

    def killed?
      raw = Config.configured("ASSISTANT_ENABLED")
      return false if raw.nil? || raw.to_s.strip.empty?

      ActiveModel::Type::Boolean.new.cast(raw) == false
    end
    private_class_method :killed?
  end
end
```

Replace `Assistant::Config.enabled?` (`config.rb:17-19`):

```ruby
    def enabled?(directory: ProviderCredentials::DEFAULT_DIRECTORY)
      Activation.state(directory: directory).active
    end
```

In `setting.rb`, make the singleton default to enabled:

```ruby
      def instance
        first_or_create!(singleton_key: true, assistant_enabled: true)
      rescue ActiveRecord::RecordNotUnique
        find_by!(singleton_key: true)
      end
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd web && bin/rails test test/services/assistant/activation_test.rb`
Expected: PASS, 6 runs.

- [ ] **Step 5: Commit**

```bash
git add web/app/services/assistant/activation.rb web/app/services/assistant/config.rb \
        web/app/models/assistant/setting.rb web/test/services/assistant/activation_test.rb
git commit -m "Derive Assistant activation from provider credential validity."
```

---

### Task 6: Graceful disable instead of boot failure

**Files:**
- Modify: `web/app/services/assistant/config.rb:66-80`,
  `web/config/initializers/assistant.rb`
- Test: `web/test/services/assistant/config_test.rb` (extend)

**Interfaces:**
- Produces: `Assistant::Config.configuration_reasons` returning an array of stable
  reason codes (`missing_admin_username`, `missing_command_allowlist`,
  `missing_ansible_module_allowlist`, `invalid_retention_window`). `validate_production!`
  is deleted. `Activation.state` returns the first configuration reason when present.

- [ ] **Step 1: Write the failing test**

```ruby
def test_missing_configuration_yields_reason_codes_instead_of_raising
  stub_methods(Assistant::Config, configured: ->(_key) { nil }) do
    reasons = Assistant::Config.configuration_reasons

    assert_includes reasons, "missing_admin_username"
    assert_includes reasons, "missing_command_allowlist"
    assert_includes reasons, "missing_ansible_module_allowlist"
  end
end

def test_the_initializer_never_raises_on_incomplete_configuration
  stub_methods(Assistant::Config, configured: ->(_key) { nil }) do
    assert_nothing_raised { Assistant::Activation.state(directory: "/nonexistent") }
  end
end

def test_a_configuration_problem_disables_rather_than_activates
  Dir.mktmpdir do |dir|
    path = Pathname.new(dir).join("assistant_anthropic_api_key")
    path.write("sk-live")
    path.chmod(0o400)

    stub_methods(Assistant::Config, configuration_reasons: -> { [ "missing_admin_username" ] }) do
      state = Assistant::Activation.state(directory: dir)

      refute_predicate state, :active
      assert_equal "missing_admin_username", state.reason
    end
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd web && bin/rails test test/services/assistant/config_test.rb`
Expected: FAIL — `configuration_reasons` is undefined and `validate_production!` raises.

- [ ] **Step 3: Implement**

Replace `validate_production!` in `config.rb`:

```ruby
    REQUIRED_SETTINGS = {
      "ADMIN_USERNAME" => "missing_admin_username",
      "CONTROL_CENTER_COMMAND_ALLOWLIST" => "missing_command_allowlist",
      "ASSISTANT_ANSIBLE_MODULE_ALLOWLIST" => "missing_ansible_module_allowlist"
    }.freeze

    # Configuration problems disable the assistant with a stable reason. They never
    # abort boot: an operator must still be able to reach the app and read why.
    def configuration_reasons
      reasons = REQUIRED_SETTINGS.filter_map do |key, reason|
        reason if configured(key).to_s.strip.blank?
      end

      begin
        transcript_retention_days
        audit_retention_days
      rescue ArgumentError
        reasons << "invalid_retention_window"
      end

      reasons
    end
```

In `activation.rb`, check configuration before credentials:

```ruby
      reasons = Config.configuration_reasons
      return State.new(active: false, available_slugs: [], reason: reasons.first) if reasons.any?
```

Replace `web/config/initializers/assistant.rb` entirely:

```ruby
Rails.application.config.after_initialize do
  state = Assistant::Activation.state
  Rails.logger.info(
    "[assistant] active=#{state.active} reason=#{state.reason} providers=#{state.available_slugs.join(',')}"
  )
end
```

The log line carries slugs and a reason code only — never a path or a value. The
`Rails.env.production?` branch is gone, so both modes run identical code.

- [ ] **Step 4: Run to verify it passes**

Run: `cd web && bin/rails test test/services/assistant/config_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web/app/services/assistant/config.rb web/app/services/assistant/activation.rb \
        web/config/initializers/assistant.rb web/test/services/assistant/config_test.rb
git commit -m "Disable the Assistant with a reason code instead of aborting boot."
```

---

### Task 7: Chat discloses why it is disabled

**Files:**
- Modify: `web/app/controllers/api/v1/assistant/base_controller.rb:111-121`,
  `web/app/javascript/controllers/assistant_controller.js`
- Test: `web/test/integration/api/v1/assistant/conversations_test.rb` (extend),
  `web/test/javascript/assistant_controller_test.mjs` (extend)

**Interfaces:**
- Produces: the bootstrap payload's `setting` object gains
  `disabled_reason` (string or null) and `providers`, an array of
  `{slug, model, retention_posture, available, reason}`.

- [ ] **Step 1: Write the failing Rails test**

```ruby
test "the bootstrap payload discloses the disabled reason without leaking paths" do
  sign_in_as_session_admin

  get "/api/v1/assistant/bootstrap", headers: { "Accept" => "application/json" }

  payload = response.parsed_body.fetch("setting")
  assert_equal "no_provider_credentials", payload.fetch("disabled_reason")
  assert_equal %w[anthropic_primary openai_primary], payload.fetch("providers").map { |p| p["slug"] }.sort
  refute_match(%r{/run/secrets}, response.body, "a secret path leaked to the browser")
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd web && bin/rails test test/integration/api/v1/assistant/conversations_test.rb`
Expected: FAIL — `disabled_reason` is absent.

- [ ] **Step 3: Implement the serializer change**

In `base_controller.rb`, extend `serialize_setting`:

```ruby
        def serialize_setting(setting)
          state = ::Assistant::Activation.state
          {
            assistant_enabled: setting.assistant_enabled?,
            infrastructure_enabled: state.active,
            effective_enabled: state.active && setting.assistant_enabled?,
            disabled_reason: disabled_reason_for(setting, state),
            providers: ::Assistant::ProviderCredentials.statuses.map do |status|
              entry = ::Assistant::ProviderCatalog.fetch!(status.slug)
              {
                slug: status.slug,
                model: entry.model,
                retention_posture: entry.retention_posture,
                available: status.available,
                reason: status.reason
              }
            end,
            transcript_retention_days: setting.transcript_retention_days,
            audit_retention_days: setting.audit_retention_days,
            disabled_at: setting.disabled_at&.iso8601,
            disabled_by_id: setting.disabled_by_id
          }
        end

        def disabled_reason_for(setting, state)
          return state.reason unless state.active
          return "disabled_by_administrator" unless setting.assistant_enabled?

          nil
        end
```

- [ ] **Step 4: Write the failing JavaScript test**

Add to `web/test/javascript/assistant_controller_test.mjs`:

```javascript
test("a disabled assistant renders its reason as text", () => {
  const ui = renderShell({ setting: { effective_enabled: false, disabled_reason: "no_provider_credentials" } })

  assert.equal(
    ui.notice.textContent,
    "Assistant disabled: no provider credentials are installed."
  )
  assert.equal(ui.composer.disabled, true)
})

test("an unknown reason falls back to a generic notice and never renders markup", () => {
  const ui = renderShell({
    setting: { effective_enabled: false, disabled_reason: "<img src=x onerror=alert(1)>" }
  })

  assert.equal(ui.notice.querySelector("img"), null)
  assert.equal(ui.notice.textContent, "Assistant disabled.")
})
```

- [ ] **Step 5: Run to verify it fails**

Run: `cd web && node --test "test/javascript/assistant_controller_test.mjs"`
Expected: FAIL — the notice element is not rendered.

- [ ] **Step 6: Implement the controller change**

In `assistant_controller.js`, add a frozen reason-to-copy map and render with
`textContent` only:

```javascript
const DISABLED_COPY = Object.freeze({
  no_provider_credentials: "Assistant disabled: no provider credentials are installed.",
  disabled_by_environment: "Assistant disabled by deployment configuration.",
  disabled_by_administrator: "Assistant disabled by an administrator.",
  missing_admin_username: "Assistant disabled: deployment configuration is incomplete.",
  missing_command_allowlist: "Assistant disabled: deployment configuration is incomplete.",
  missing_ansible_module_allowlist: "Assistant disabled: deployment configuration is incomplete.",
  invalid_retention_window: "Assistant disabled: retention configuration is invalid."
})

renderDisabled(reason) {
  this.noticeTarget.textContent = DISABLED_COPY[reason] || "Assistant disabled."
  this.composerTarget.disabled = true
}
```

Server-supplied reasons are looked up in a fixed map, never interpolated, so an
unexpected value degrades to the generic line instead of reaching the DOM.

- [ ] **Step 7: Run both suites to verify they pass**

Run: `cd web && node --test "test/javascript/assistant_controller_test.mjs" && bin/rails test test/integration/api/v1/assistant/`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add web/app/controllers/api/v1/assistant/base_controller.rb \
        web/app/javascript/controllers/assistant_controller.js \
        web/test/javascript/assistant_controller_test.mjs \
        web/test/integration/api/v1/assistant/conversations_test.rb
git commit -m "Disclose the Assistant disabled reason in the chat shell."
```

---

### Task 8: The gateway idles instead of exiting without provider credentials

**Files:**
- Modify: `assistant/gateway/internal/config/config.go:38-52`,
  `assistant/gateway/cmd/hunter-assistant-gateway/main.go:30-48`
- Test: `assistant/gateway/internal/config/config_test.go`,
  `assistant/gateway/cmd/hunter-assistant-gateway/main_test.go`

**Why:** `main.go:36` and `main.go:40` currently call `log.Fatal` when either provider
key is missing, so the gateway demands *both* keys and dies otherwise. With the
Compose profile removed in Task 9, that would crash-loop on a fresh deployment and
would make an Anthropic-only install impossible. The gateway is the only assistant
service that can legitimately be unconfigured, so it is the only one needing this.

**Interfaces:**
- Produces: `config.Load()` returns `Config` with
  `AvailableProfiles []string` and never fails on an absent provider key.
  `config.ProviderStatus(ref) string` returns the same reason vocabulary Rails uses:
  `valid`, `absent`, `empty`, `placeholder`, `bad_mode`, `symlink`, `unreadable`.
- Consumes: the path contract; provider keys at `/run/secrets/<secret_file>`.

- [ ] **Step 1: Write the failing test**

```go
func TestLoadSucceedsWithNoProviderKeys(t *testing.T) {
	dir := t.TempDir()
	writeMachineSecrets(t, dir)

	settings, err := config.LoadFrom(dir)
	if err != nil {
		t.Fatalf("Load failed with no provider keys: %v", err)
	}
	if len(settings.AvailableProfiles) != 0 {
		t.Fatalf("expected no available profiles, got %v", settings.AvailableProfiles)
	}
}

func TestLoadSucceedsWithOnlyAnthropicConfigured(t *testing.T) {
	dir := t.TempDir()
	writeMachineSecrets(t, dir)
	writeSecret(t, dir, "assistant_anthropic_api_key", "sk-live", 0o400)

	settings, err := config.LoadFrom(dir)
	if err != nil {
		t.Fatalf("Load failed with one provider key: %v", err)
	}
	if got := settings.AvailableProfiles; len(got) != 1 || got[0] != "anthropic_primary" {
		t.Fatalf("expected only anthropic_primary, got %v", got)
	}
}

func TestProviderStatusReasonsAreStableAndLeakNothing(t *testing.T) {
	dir := t.TempDir()
	writeSecret(t, dir, "assistant_openai_api_key", "replace_with_openai_api_key", 0o400)
	writeSecret(t, dir, "assistant_anthropic_api_key", "sk-canary", 0o644)

	if got := config.ProviderStatusIn(dir, "openai_primary"); got != "placeholder" {
		t.Fatalf("expected placeholder, got %q", got)
	}
	if got := config.ProviderStatusIn(dir, "anthropic_primary"); got != "bad_mode" {
		t.Fatalf("expected bad_mode, got %q", got)
	}
	if strings.Contains(config.ProviderStatusIn(dir, "anthropic_primary"), "sk-canary") {
		t.Fatal("a reason code leaked the secret value")
	}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd assistant/gateway && go test ./internal/config/`
Expected: FAIL — `LoadFrom`, `AvailableProfiles` and `ProviderStatusIn` are undefined,
and `Load` rejects a missing provider key.

- [ ] **Step 3: Implement**

In `config.go`, split machine credentials from provider credentials. Machine
credentials (MCP token, AMQP password) remain mandatory — they are always generated by
Task 3, so their absence is a genuine fault. Provider keys become optional:

```go
func LoadFrom(secretDir string) (Config, error) {
	mcpToken, err := readSecret(filepath.Join(machineSecretDir, "assistant_gateway_mcp_token"))
	if err != nil {
		return Config{}, errors.New("gateway MCP credential unavailable")
	}
	amqpPassword, err := readSecret(filepath.Join(machineSecretDir, "assistant_gateway_amqp_password"))
	if err != nil {
		return Config{}, errors.New("gateway AMQP credential unavailable")
	}

	available := make([]string, 0, len(defaultSecretPaths))
	for reference := range defaultSecretPaths {
		if ProviderStatusIn(secretDir, reference) == "valid" {
			available = append(available, reference)
		}
	}
	sort.Strings(available)

	return Config{
		GatewayMCPToken:   mcpToken,
		AMQPPassword:      amqpPassword,
		ProviderSecrets:   NewSecretResolver(nil),
		AvailableProfiles: available,
	}, nil
}
```

In `main.go`, delete the two `log.Fatal` calls at lines 36 and 40. Replace with:

```go
	if len(settings.AvailableProfiles) == 0 {
		log.Print("assistant gateway idle: no provider credentials installed")
		serveHealthOnly(ctx)   // ready=false, never consumes the turn queue
		return
	}
	log.Printf("assistant gateway ready: profiles=%s", strings.Join(settings.AvailableProfiles, ","))
```

The idle path serves the existing health endpoint reporting `ready: false` with a
reason code, and does not open the AMQP consumer. A turn naming an unavailable
profile is answered with the existing stable terminal error event rather than a panic.

- [ ] **Step 4: Run to verify it passes**

Run: `cd assistant/gateway && go vet ./... && go test -race ./...`
Expected: PASS across all six packages.

- [ ] **Step 5: Commit**

```bash
git add assistant/gateway/
git commit -m "Idle the Assistant gateway when no provider credential is installed."
```

---

### Task 9: Compose wiring and the secret path contract

**Files:**
- Modify: `docker-compose.yaml`, `docker-compose.prod.yaml`,
  `assistant/gateway/internal/config/config.go`,
  `assistant/mcp/internal/config/config.go`,
  `assistant/validator/internal/config/config.go`,
  `web/app/services/assistant/broker.rb`
- Test: `web/test/contracts/assistant_secret_paths_test.rb`,
  `web/test/config/assistant_compose_test.rb` (extend)

**Interfaces:**
- Consumes: the path contract from the File Structure section.
- Produces: `assistant-bootstrap` service; `assistant_secrets` volume; no
  `profiles:` on any assistant service.

- [ ] **Step 1: Write the failing contract test**

```ruby
require "minitest/autorun"
require "pathname"
require "yaml"

class AssistantSecretPathsTest < Minitest::Test
  ROOT = Pathname.new(__dir__).join("../../..").expand_path.freeze
  VOLUME_PATH = "/run/assistant/secrets".freeze
  MACHINE_SECRETS = %w[
    assistant_rails_amqp_password assistant_gateway_amqp_password
    assistant_validator_amqp_password assistant_rabbitmq_provision_password
    assistant_gateway_mcp_token assistant_mcp_hunter_token
  ].freeze

  def test_go_services_read_machine_credentials_from_the_volume
    %w[gateway mcp validator].each do |service|
      body = Dir.glob(ROOT.join("assistant/#{service}/internal/config/*.go"))
        .reject { |path| path.end_with?("_test.go") }
        .map { |path| File.read(path) }.join

      refute_match(%r{"/run/secrets/assistant_(rails|gateway|validator)_amqp_password"}, body,
        "#{service} still reads a machine credential from the Compose secret mount")
      assert_includes body, VOLUME_PATH, "#{service} does not read from #{VOLUME_PATH}"
    end
  end

  def test_the_catalog_secret_file_matches_the_gateway_mapping
    catalog = YAML.safe_load_file(ROOT.join("web/config/assistant_provider_catalog.yml"), aliases: false)
    gateway = File.read(ROOT.join("assistant/gateway/internal/config/config.go"))

    catalog.each_value do |entry|
      assert_includes gateway, "/run/secrets/#{entry.fetch('secret_file')}",
        "the gateway does not read #{entry.fetch('secret_file')}"
    end
  end

  def test_no_assistant_service_is_profile_gated
    %w[docker-compose.yaml docker-compose.prod.yaml].each do |name|
      body = ROOT.join(name).read

      refute_includes body, 'profiles: ["assistant"]',
        "#{name} still hides assistant services behind a Compose profile"
    end
  end

  def test_every_machine_secret_is_volume_backed_not_file_backed
    %w[docker-compose.yaml docker-compose.prod.yaml].each do |name|
      body = ROOT.join(name).read

      MACHINE_SECRETS.each do |secret|
        refute_match(/^  #{secret}:\n    file:/m, body,
          "#{name} still defines #{secret} as a file-backed Compose secret")
      end
      assert_includes body, "assistant_secrets:", "#{name} lacks the assistant secrets volume"
    end
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd web && ruby -Itest test/contracts/assistant_secret_paths_test.rb`
Expected: FAIL on all four tests.

- [ ] **Step 3: Update the Go readers**

In each of the three services, change the machine-credential paths from
`/run/secrets/<name>` to `/run/assistant/secrets/<name>`. Provider key paths in
`assistant/gateway/internal/config/config.go:20-21` stay at `/run/secrets/`. Update
the corresponding `_test.go` fixtures. Run `gofmt -l` and expect no output.

- [ ] **Step 4: Update Rails broker credential loading**

In `web/app/services/assistant/broker.rb`, read
`/run/assistant/secrets/assistant_rails_amqp_password`, keeping the existing
`ASSISTANT_AMQP_PASSWORD_FILE` override for tests.

- [ ] **Step 5: Update both compose files identically**

For each file:

0. **Delete every `ASSISTANT_ENABLED: ${ASSISTANT_ENABLED:-false}` line from both
   compose files, and remove `ASSISTANT_ENABLED=false` from `.env.example`.** This is
   load-bearing: Task 5 makes `ASSISTANT_ENABLED` a kill override, so a baked-in
   `false` default would set the variable on every service and force the assistant off
   permanently, defeating the entire plan. The variable must be *unset* by default so
   activation can derive. Verify with a test asserting neither compose file nor
   `.env.example` assigns `ASSISTANT_ENABLED` a default value.
1. Delete `profiles: ["assistant"]` from `assistant-events`, `assistant-egress`,
   `hunter-mcp`, `assistant-validator`, `assistant-gateway`.
2. Delete the six machine-credential entries from the top-level `secrets:` block and
   every `secrets:` mount that referenced them.
3. Add the volume: `assistant_secrets:` under `volumes:`.
4. Add the bootstrap service, before its dependents:

```yaml
  assistant-bootstrap:
    build:              # prod: image: ${REGISTRY_HOST...}-web:${ASSISTANT_IMAGE_TAG:-latest}
      context: .
      dockerfile: Dockerfile
    command: ["sh", "-c", "/app/ops/assistant/bootstrap.sh && bundle exec ruby /app/ops/assistant/bootstrap_service_token.rb"]
    environment:
      RAILS_ENV: development      # prod: production
      ASSISTANT_SECRET_TARGET: /run/assistant/secrets
      ASSISTANT_MCP_TOKEN_PATH: /run/assistant/secrets/assistant_mcp_hunter_token
    volumes:
      - assistant_secrets:/run/assistant/secrets
    networks:
      - default
    depends_on:
      db:
        condition: service_healthy
    restart: "no"
    user: "1000:1000"
    read_only: true
    tmpfs:
      - /tmp
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    pids_limit: 64
```

5. Mount `assistant_secrets:/run/assistant/secrets:ro` on `web`, `assistant-events`,
   `assistant-gateway`, `hunter-mcp`, `assistant-validator`, `rabbitmq` and
   `assistant-rabbitmq-init`.
6. Add `assistant-bootstrap: {condition: service_completed_successfully}` to the
   `depends_on` of `assistant-rabbitmq-init` and every assistant service.

- [ ] **Step 6: Extend the compose parity test**

```ruby
def test_hardening_directives_match_between_both_compose_files
  counts = %w[docker-compose.yaml docker-compose.prod.yaml].map do |name|
    body = ROOT.join(name).read
    %w[read_only security_opt cap_drop no-new-privileges tmpfs pids_limit].to_h do |directive|
      [ directive, body.scan(directive).length ]
    end
  end

  assert_equal counts.first, counts.last,
    "the compose files have diverged in runtime hardening"
end
```

- [ ] **Step 7: Run to verify it passes**

Run: `cd web && ruby -Itest test/contracts/assistant_secret_paths_test.rb && ruby -Itest test/config/assistant_compose_test.rb`
Expected: PASS. Then in each Go service: `go vet ./... && go test -race ./...`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add docker-compose.yaml docker-compose.prod.yaml assistant/ \
        web/app/services/assistant/broker.rb web/test/contracts/ \
        web/test/config/assistant_compose_test.rb
git commit -m "Start every Assistant service by default and read machine credentials from the bootstrap volume."
```

---

### Task 10: Documentation and verification

**Files:**
- Modify: `secrets/README.md`, `docs/runbooks/hunter-assistant-credential-rotation.md`,
  `docs/runbooks/hunter-assistant-incident-response.md`,
  `docs/security/hunter-assistant-production-checklist.md`,
  `docs/superpowers/plans/2026-07-26-hunter-assistant-checkpoint.md`
- Create: `docs/runbooks/hunter-assistant-enablement.md`

- [ ] **Step 0: Repair dangling references left by Tasks 2 and 9**

`ops/assistant/check_secret_leaks.sh` and `ops/assistant/rotation_drill.sh` still
reference `ops/assistant/generate_secrets.sh` (renamed to `prepare_secrets.sh` in Task 2)
and the `secrets/dev` / `secrets/prod` directories (deleted in Task 2). Neither is wired
into boot or the test suite, which is why earlier tasks left them, but both are release
gates the production checklist depends on, so a stale path silently weakens a gate. Update
both to the single `secrets/` directory and the new script name, and confirm
`web/test/config/assistant_release_gate_test.rb` still passes.

- [ ] **Step 1: Rewrite `secrets/README.md`**

Document the whole operator procedure as: create `secrets/`, put a provider key in
`assistant_openai_api_key` and/or `assistant_anthropic_api_key` at mode `0600` owned
`1000:1000`, run `docker compose up`. State that an empty file means that provider
stays disabled and the chat says so. Remove every reference to `dev`/`prod`/`disabled`
directories, `ASSISTANT_SECRET_DIR`, and manual `rake assistant:service_tokens:create`.

- [ ] **Step 2: Update the rotation runbook**

Provider key rotation: replace the file, restart `assistant-gateway`. Machine
credential rotation: delete the file from the `assistant_secrets` volume and restart
`assistant-bootstrap`, then dependents. `ASSISTANT_RABBITMQ_REPROVISION=true` still
forces broker re-provisioning.

- [ ] **Step 3: Update the production checklist**

Add the `assistant_secrets` volume to the credential matrix and the backup-retention
review. Replace the "`ASSISTANT_ENABLED=false` is present" line with: activation is
derived from provider key presence; verify only intended keys are installed and the
kill switch is available. Add a gate row for the live `compose up` acceptance run.

- [ ] **Step 4: Rewrite the checkpoint document**

`docs/superpowers/plans/2026-07-26-hunter-assistant-checkpoint.md` currently claims
Tasks 14–18 are unimplemented and the effort is 60–65% complete. Both are false.
Replace it with the true state: Tasks 1–18 of the base plan are implemented,
non-container suites pass, container-level gates remain outstanding, and this
activation plan is in progress.

- [ ] **Step 5: Run the full suites**

```bash
cd web && DB_USERNAME=... DB_PASSWORD=... DB_HOST=172.17.0.1 DB_PORT=5433 \
  DB_DATABASE_TEST=hunter_test bin/rails test
node --test "test/javascript/*_test.mjs"
for service in gateway mcp validator; do (cd ../assistant/$service && go vet ./... && go test -race ./...); done
```

Expected: 0 failures in each. Record actual counts — do not claim a result without
the output.

- [ ] **Step 6: Operator acceptance run (Docker required)**

The implementation environment has no Docker. The operator runs, on the deployment
host, and reports output:

1. `docker compose up --build` with **no provider key files at all** (`secrets/`
   containing only `.keep`, `README.md`, `examples/`). Expect: every service healthy,
   no crash loop, chat bubble present, clicking shows "Assistant disabled: no
   provider credentials are installed."
2. Repeat with two **empty** key files present. Expect identical behaviour — absent
   and empty must be indistinguishable to the operator.
2. Write a real Anthropic key into `secrets/assistant_anthropic_api_key`, `chmod 0600`,
   `chown 1000:1000`, restart. Expect: Anthropic selectable, OpenAI still shown
   disabled, and a chat turn completing end to end.
3. `docker compose config` output reviewed for any secret value. Expect none.

- [ ] **Step 7: Commit**

```bash
git add secrets/README.md docs/
git commit -m "Document zero-step Assistant enablement and refresh the checkpoint."
```

---

## Self-Review

**Spec coverage.** Operator installs the key files → Tasks 2, 10. `compose up` starts
every service with no profile switch → Task 9. Machine credentials auto-generated →
Task 3. Absent or empty key means disabled → Tasks 4, 5. Only one provider installed
still works → Task 8. Reason surfaced in chat on click → Task 7. Never crash-loops →
Tasks 6 (Rails) and 8 (gateway). One codebase, no dev/prod split → Tasks 2, 6, 9.
Threat-model delta → Task 1. Broker architecture unchanged → no task touches the queue
topology, MCP catalog, sanitizers or grants.

**Known deferrals.** Container-level gates (image builds, live Squid egress, network
denial, AppArmor/seccomp probes, SBOM, image scanning, rotation drill) stay on the
acceptance list from the base plan and are unaffected by this work. The independent
security review in the production checklist remains a human gate.

**Type consistency.** `Status = Data.define(:slug, :reason, :available)` and
`State = Data.define(:active, :available_slugs, :reason)` are used with those exact
field names in Tasks 4–7. `ProviderCredentials.statuses`, `.available_slugs`,
`.status`, `Activation.state`, `.audit_payload`, and `Config.configuration_reasons`
are the only cross-task entry points.
