# Control Center Ansible Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Hunter's Active Record encryption foundation, centralize runner capabilities, and deliver fully functional encrypted Ansible SSH credential management in Settings and the Control Center API.

**Architecture:** Rails owns credential metadata and encrypted secret fields in PostgreSQL. Settings uses ordinary session-authenticated forms; the JSON API uses Hunter's existing cookie/CSRF or scoped bearer authentication and never serializes a decrypted secret. SSH public-key fingerprints are derived in-process with Net::SSH so private-key passphrases never enter a child-process argument list or environment.

**Tech Stack:** Ruby 3.3.6, Rails 8.1, PostgreSQL, Active Record Encryption, net-ssh 7.3.3, ed25519 1.4.0, bcrypt_pbkdf 1.1.2, Tailwind CSS, Minitest.

## Global Constraints

- The app lives in `web/`; run Rails tests inside the Docker Compose web service.
- Preserve all unrelated worktree changes. Another contributor is modifying Whiterabbit import files.
- Namespace domain code under `ControlCenter::Ansible` and API code under `Api::V1::ControlCenter::Ansible`.
- Hunter has one trusted administrator; do not add RBAC.
- Use non-deterministic encryption for every credential secret.
- Encryption keys must never be committed or stored in PostgreSQL.
- Browser/API reads return only credential metadata, fingerprints, and configured booleans.
- Blank secret updates retain the existing value; clearing a secret requires an explicit clear flag.
- Keep connection credentials separate from Ansible variables.
- Do not commit during execution unless the user explicitly authorizes commits. Each task includes a gated checkpoint command for use only after that authorization.

---

## File Structure

### New files

- `web/config/initializers/active_record_encryption.rb` — environment-key wiring and production fail-closed check.
- `web/test/config/active_record_encryption_test.rb` — encryption configuration regression tests.
- `web/db/migrate/20260723010001_create_control_center_ansible_credentials.rb` — credential table.
- `web/app/models/control_center/ansible/credential.rb` — encrypted credential model and metadata serializer helpers.
- `web/app/services/control_center/ansible/credential_fingerprint.rb` — in-memory private-key validation and SHA256 public fingerprint derivation.
- `web/app/services/control_center/ansible/credential_updater.rb` — shared write-only secret update semantics.
- `web/test/models/control_center/ansible/credential_test.rb` — encryption and validation tests.
- `web/test/services/control_center/ansible/credential_fingerprint_test.rb` — argv/parse/error tests.
- `web/test/services/control_center/ansible/credential_updater_test.rb` — retain/replace/clear tests.
- `web/app/controllers/settings/ansible_credentials_controller.rb` — Settings create/update/destroy actions.
- `web/app/views/settings/_ansible_credentials.html.erb` — credential Settings section.
- `web/test/integration/settings/ansible_credentials_test.rb` — Settings flow tests.
- `web/app/controllers/api/v1/control_center/ansible/credentials_controller.rb` — write-only-secret JSON CRUD.
- `web/test/integration/api/v1/control_center/ansible/credentials_test.rb` — API auth and serialization tests.

### Modified files

- `web/config/application.rb` — map encryption environment variables into Rails config.
- `web/config/environments/test.rb` — fixed non-production encryption keys.
- `web/config/initializers/filter_parameter_logging.rb` — filter every secret alias and encrypted payload field.
- `.env.example` — document required production keys.
- `docker-compose.yaml` — safe development-only encryption defaults.
- `docker-compose.prod.yaml` — pass required deployment secrets.
- `web/Gemfile` and `web/Gemfile.lock` — pin in-process SSH key parsing dependencies.
- `web/app/models/runner.rb` — central `Runner::KINDS` capability allowlist.
- `web/app/views/settings/_runners.html.erb` — render centralized runner kinds.
- `web/test/models/runner_test.rb` and `web/test/integration/settings/runners_test.rb` — Ansible and invalid-kind coverage.
- `web/config/routes.rb` — Settings and API credential routes.
- `web/app/controllers/settings_controller.rb` and `web/app/views/settings/show.html.erb` — load/render credential section.
- `web/app/models/user.rb` — creator association.
- `web/config/openapi/control_center.yaml` — credential API contract.

---

### Task 1: Configure Active Record Encryption and fail closed in production

**Files:**
- Create: `web/config/initializers/active_record_encryption.rb`
- Create: `web/test/config/active_record_encryption_test.rb`
- Modify: `web/config/application.rb`
- Modify: `web/config/environments/test.rb`
- Modify: `web/config/initializers/filter_parameter_logging.rb`
- Modify: `.env.example`
- Modify: `docker-compose.yaml`
- Modify: `docker-compose.prod.yaml`

**Interfaces:**
- Produces: `ActiveRecord::Encryption.config` with `primary_key`, `deterministic_key`, and `key_derivation_salt` configured before encrypted models load.
- Produces: environment names `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`, `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY`, `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT`.

- [ ] **Step 1: Write the failing configuration test**

```ruby
# web/test/config/active_record_encryption_test.rb
require "test_helper"

class ActiveRecordEncryptionTest < ActiveSupport::TestCase
  test "test has an explicit complete key set" do
    config = ActiveRecord::Encryption.config
    assert config.primary_key.present?
    assert config.deterministic_key.present?
    assert config.key_derivation_salt.present?
  end

  test "unencrypted fallback is disabled" do
    assert_equal false, ActiveRecord::Encryption.config.support_unencrypted_data
  end

  test "all Ansible secret aliases are filtered" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    values = %w[
      private_key ssh_password private_key_passphrase become_password
      serialized_value execution_payload
    ].index_with { "do-not-log" }
    assert values.keys.all? { |key| filter.filter(values).fetch(key) == "[FILTERED]" }
  end
end
```

- [ ] **Step 2: Run the test and verify the missing-key failure**

Run: `docker compose exec web bin/rails test test/config/active_record_encryption_test.rb`

Expected: FAIL because the test environment has no Active Record encryption key set.

- [ ] **Step 3: Wire environment keys and secure defaults**

Add inside `Hunter::Application` in `web/config/application.rb`:

```ruby
    encryption_env = {
      primary_key: "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY",
      deterministic_key: "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY",
      key_derivation_salt: "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"
    }
    encryption_env.each do |setting, env_name|
      value = ENV[env_name].presence
      config.active_record.encryption.public_send("#{setting}=", value) if value
    end
    config.active_record.encryption.support_unencrypted_data = false
    config.active_record.encryption.store_key_references = true
```

Add fixed test-only values inside `Rails.application.configure` in
`web/config/environments/test.rb`:

```ruby
  config.active_record.encryption.primary_key = "8f1f681a40844730f7353c66412dca1e"
  config.active_record.encryption.deterministic_key = "1a80ad4db8344b4ca1f9f874ac1a1c3f"
  config.active_record.encryption.key_derivation_salt = "38c752e93e534c1f82620f93fc92a6bd"
  config.active_record.encryption.support_unencrypted_data = false
```

Create the production guard:

```ruby
# web/config/initializers/active_record_encryption.rb
Rails.application.config.after_initialize do
  next unless Rails.env.production?

  config = ActiveRecord::Encryption.config
  missing = %i[primary_key deterministic_key key_derivation_salt].select do |name|
    config.public_send(name).blank?
  end
  next if missing.empty?

  names = missing.map { |name| "ACTIVE_RECORD_ENCRYPTION_#{name.to_s.upcase}" }
  raise "Missing Active Record encryption secrets: #{names.join(', ')}"
end
```

Add to `.env.example`:

```dotenv
# Active Record application-level encryption. Generate with:
#   cd web && bin/rails db:encryption:init
# Never reuse the development defaults in production.
ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=
ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=
ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=
```

Add to the development `web.environment` in `docker-compose.yaml`:

```yaml
      ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY: ${ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY:-dev-primary-key-32-bytes-only-01}
      ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY: ${ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY:-dev-deterministic-key-32-byte-01}
      ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT: ${ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT:-dev-key-derivation-salt-32-byte01}
```

Add to the production `web.environment` in `docker-compose.prod.yaml` without defaults:

```yaml
      ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY: ${ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY}
      ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY: ${ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY}
      ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT: ${ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT}
```

Append explicit aliases to `web/config/initializers/filter_parameter_logging.rb`
(the existing partial filters remain in place):

```ruby
  :private_key, :ssh_password, :private_key_passphrase, :become_password,
  :serialized_value, :execution_payload
```

- [ ] **Step 4: Rebuild the web image and run the focused test**

Run: `docker compose build web && docker compose up -d web`

Expected: image builds and the web service becomes healthy/running.

Run: `docker compose exec web bin/rails test test/config/active_record_encryption_test.rb`

Expected: PASS, including the configuration and parameter-filter assertions.

- [ ] **Step 5: Checkpoint**

Run: `git diff --check`

Expected: no whitespace errors. If and only if the user has explicitly authorized commits:

```bash
git add web/config/application.rb web/config/environments/test.rb web/config/initializers/active_record_encryption.rb web/config/initializers/filter_parameter_logging.rb web/test/config/active_record_encryption_test.rb .env.example docker-compose.yaml docker-compose.prod.yaml
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Configure Active Record encryption for Hunter secrets"
```

### Task 2: Centralize and validate runner capabilities

**Files:**
- Modify: `web/app/models/runner.rb`
- Modify: `web/app/views/settings/_runners.html.erb`
- Modify: `web/test/models/runner_test.rb`
- Modify: `web/test/integration/settings/runners_test.rb`

**Interfaces:**
- Produces: `Runner::KINDS #=> %w[curl ansible]`.
- Preserves: `RunnerJob::KINDS #=> %w[curl]`; Ansible is a machine capability, not a curl job kind.

- [ ] **Step 1: Add failing model and Settings tests**

Append to `web/test/models/runner_test.rb`:

```ruby
  test "accepts ansible and rejects unknown capabilities" do
    runner, = Runner.generate(name: "ansible-executor", kinds: %w[ansible])
    assert_equal %w[ansible], runner.kinds

    assert_raises(ActiveRecord::RecordInvalid) do
      Runner.generate(name: "unsafe", kinds: %w[shell])
    end
  end
```

Append to `web/test/integration/settings/runners_test.rb`:

```ruby
  test "settings can mint an ansible-only runner" do
    sign_in_as(@user)
    post settings_runners_path, params: { name: "ansible-executor", kinds: ["ansible"] }
    assert_redirected_to settings_path
    assert_equal %w[ansible], Runner.find_by!(name: "ansible-executor").kinds
  end
```

- [ ] **Step 2: Run the focused tests and verify failure**

Run: `docker compose exec web bin/rails test test/models/runner_test.rb test/integration/settings/runners_test.rb`

Expected: FAIL because unknown kinds are accepted and the Settings checkbox list contains only curl.

- [ ] **Step 3: Add the centralized allowlist and use it in Settings**

In `web/app/models/runner.rb`, add:

```ruby
  KINDS = %w[curl ansible].freeze

  before_validation :normalize_kinds
  validate :kinds_are_supported

  private

  def normalize_kinds
    self.kinds = Array(kinds).map { |kind| kind.to_s.strip }.reject(&:blank?).uniq
  end

  def kinds_are_supported
    unknown = kinds - KINDS
    errors.add(:kinds, "contains unsupported values: #{unknown.join(', ')}") if unknown.any?
  end
```

Keep the existing presence validation. In
`web/app/views/settings/_runners.html.erb`, replace `RunnerJob::KINDS.each` with:

```erb
<% Runner::KINDS.each do |kind| %>
```

- [ ] **Step 4: Run focused and regression tests**

Run: `docker compose exec web bin/rails test test/models/runner_test.rb test/models/runner_job_test.rb test/integration/settings/runners_test.rb test/integration/api/runner/jobs_test.rb`

Expected: PASS.

- [ ] **Step 5: Checkpoint**

Run: `git diff --check`

Expected: clean. With explicit commit authorization only:

```bash
git add web/app/models/runner.rb web/app/views/settings/_runners.html.erb web/test/models/runner_test.rb web/test/integration/settings/runners_test.rb
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Add Ansible as a scoped runner capability"
```

### Task 3: Add the encrypted credential model and fingerprint service

**Files:**
- Create: `web/db/migrate/20260723010001_create_control_center_ansible_credentials.rb`
- Create: `web/app/models/control_center/ansible/credential.rb`
- Create: `web/app/services/control_center/ansible/credential_fingerprint.rb`
- Create: `web/test/models/control_center/ansible/credential_test.rb`
- Create: `web/test/services/control_center/ansible/credential_fingerprint_test.rb`
- Modify: `web/app/models/user.rb`
- Modify: `web/Gemfile`
- Modify: `web/Gemfile.lock`

**Interfaces:**
- Produces: `ControlCenter::Ansible::Credential` with `AUTH_TYPES = %w[private_key password]`.
- Produces: `ControlCenter::Ansible::CredentialFingerprint.call(private_key:, passphrase:) -> Result(fingerprint:, error:)`, entirely in the Rails process.
- Encrypted attributes: `private_key`, `ssh_password`, `private_key_passphrase`, `become_password`.

- [ ] **Step 1: Write failing model tests**

```ruby
# web/test/models/control_center/ansible/credential_test.rb
require "test_helper"

class ControlCenter::Ansible::CredentialTest < ActiveSupport::TestCase
  setup { @user = users(:one) }

  test "password secrets are encrypted in the raw database row" do
    credential = ControlCenter::Ansible::Credential.create!(
      name: "workers-password", auth_type: "password", username: "ansible",
      ssh_password: "fleet-secret", become_password: "sudo-secret", created_by: @user
    )

    row = ActiveRecord::Base.connection.select_one(<<~SQL)
      SELECT ssh_password, become_password
      FROM control_center_ansible_credentials
      WHERE id = #{credential.id.to_i}
    SQL
    refute_includes row.fetch("ssh_password"), "fleet-secret"
    refute_includes row.fetch("become_password"), "sudo-secret"
    assert_equal "fleet-secret", credential.reload.ssh_password
  end

  test "requires the secret matching its authentication type" do
    password = ControlCenter::Ansible::Credential.new(name: "p", auth_type: "password", username: "a")
    refute password.valid?
    assert_includes password.errors[:ssh_password], "must be configured"

    key = ControlCenter::Ansible::Credential.new(name: "k", auth_type: "private_key", username: "a")
    refute key.valid?
    assert_includes key.errors[:private_key], "must be configured"
  end

  test "configured flags do not expose values" do
    credential = ControlCenter::Ansible::Credential.new(
      private_key: "secret", private_key_passphrase: "phrase", become_password: "sudo"
    )
    assert credential.private_key_configured?
    assert credential.private_key_passphrase_configured?
    assert credential.become_password_configured?
    refute credential.ssh_password_configured?
  end
end
```

- [ ] **Step 2: Run the model test and verify missing constant/table failure**

Run: `docker compose exec web bin/rails test test/models/control_center/ansible/credential_test.rb`

Expected: FAIL with missing `ControlCenter::Ansible::Credential` or table.

- [ ] **Step 3: Add the migration and model**

```ruby
# web/db/migrate/20260723010001_create_control_center_ansible_credentials.rb
class CreateControlCenterAnsibleCredentials < ActiveRecord::Migration[8.1]
  def change
    create_table :control_center_ansible_credentials do |t|
      t.string :name, null: false
      t.string :auth_type, null: false
      t.string :username, null: false
      t.text :private_key
      t.text :ssh_password
      t.text :private_key_passphrase
      t.text :become_password
      t.string :public_key_fingerprint
      t.references :created_by, foreign_key: { to_table: :users }, null: false
      t.datetime :last_used_at
      t.timestamps
    end
    add_index :control_center_ansible_credentials, "lower(name)", unique: true,
      name: "idx_ansible_credentials_lower_name"
  end
end
```

```ruby
# web/app/models/control_center/ansible/credential.rb
module ControlCenter
  module Ansible
    class Credential < ApplicationRecord
      self.table_name = "control_center_ansible_credentials"

      AUTH_TYPES = %w[private_key password].freeze
      SECRET_FIELDS = %i[private_key ssh_password private_key_passphrase become_password].freeze

      belongs_to :created_by, class_name: "User", inverse_of: :control_center_ansible_credentials

      encrypts(*SECRET_FIELDS)

      before_validation { self.name = name.to_s.strip }
      validates :name, presence: true, uniqueness: { case_sensitive: false }
      validates :username, presence: true
      validates :auth_type, inclusion: { in: AUTH_TYPES }
      validates :private_key, :ssh_password, :private_key_passphrase, :become_password,
                length: { maximum: 64.kilobytes }, allow_nil: true
      validate :required_auth_secret
      validate :derive_fingerprint, if: :private_key_changed_for_validation?

      SECRET_FIELDS.each do |field|
        define_method("#{field}_configured?") { public_send(field).present? }
      end

      private

      def required_auth_secret
        if auth_type == "private_key" && private_key.blank?
          errors.add(:private_key, "must be configured")
        elsif auth_type == "password" && ssh_password.blank?
          errors.add(:ssh_password, "must be configured")
        end
      end

      def private_key_changed_for_validation?
        auth_type == "private_key" && private_key.present? &&
          (new_record? || will_save_change_to_private_key? || will_save_change_to_private_key_passphrase?)
      end

      def derive_fingerprint
        result = CredentialFingerprint.call(private_key: private_key, passphrase: private_key_passphrase)
        if result.error
          errors.add(:private_key, result.error)
        else
          self.public_key_fingerprint = result.fingerprint
        end
      end
    end
  end
end
```

Add to `User`:

```ruby
  has_many :control_center_ansible_credentials,
           class_name: "ControlCenter::Ansible::Credential",
           foreign_key: :created_by_id,
           dependent: :nullify,
           inverse_of: :created_by
```

- [ ] **Step 4: Pin in-process key parsing and write the failing fingerprint service tests**

Add to `web/Gemfile`:

```ruby
gem "net-ssh", "~> 7.3.3"
gem "ed25519", "~> 1.4.0"
gem "bcrypt_pbkdf", "~> 1.1.2"
```

Run `docker compose run --rm web bundle lock` so `web/Gemfile.lock` records the
resolved dependency graph. Do not loosen these pins without re-running the key
format tests.

```ruby
# web/test/services/control_center/ansible/credential_fingerprint_test.rb
require "test_helper"
require "openssl"

class ControlCenter::Ansible::CredentialFingerprintTest < ActiveSupport::TestCase
  Subject = ControlCenter::Ansible::CredentialFingerprint

  test "returns the OpenSSH SHA256 fingerprint without spawning a process" do
    key = OpenSSL::PKey::RSA.new(2048)
    pem = key.export(OpenSSL::Cipher.new("aes-256-cbc"), "phrase")
    expected = Base64.strict_encode64(Digest::SHA256.digest(key.to_blob)).delete_suffix("=")

    result = Subject.call(private_key: pem, passphrase: "phrase")

    assert_equal "SHA256:#{expected}", result.fingerprint
    assert_nil result.error
  end

  test "normalizes an invalid-key failure" do
    result = Subject.call(private_key: "broken", passphrase: nil)
    assert_nil result.fingerprint
    assert_equal "is invalid or its passphrase is incorrect", result.error
  end
end
```

- [ ] **Step 5: Implement in-memory fingerprint derivation**

```ruby
# web/app/services/control_center/ansible/credential_fingerprint.rb
require "base64"
require "digest"
require "net/ssh"

module ControlCenter
  module Ansible
    module CredentialFingerprint
      Result = Data.define(:fingerprint, :error)
      module_function

      def call(private_key:, passphrase: nil)
        key = Net::SSH::KeyFactory.load_data_private_key(
          private_key.to_s, passphrase.presence, false, "Hunter Ansible credential"
        )
        digest = Base64.strict_encode64(Digest::SHA256.digest(key.to_blob)).delete_suffix("=")
        Result.new(fingerprint: "SHA256:#{digest}", error: nil)
      rescue Net::SSH::Exception, OpenSSL::PKey::PKeyError, ArgumentError
        Result.new(fingerprint: nil, error: "is invalid or its passphrase is incorrect")
      end
    end
  end
end
```

- [ ] **Step 6: Install, migrate, rebuild, and run tests**

Run: `docker compose build web && docker compose up -d web && docker compose exec web bin/rails db:migrate`

Expected: dependency installation, migration, and web restart succeed.

Run: `docker compose exec web bin/rails test test/models/control_center/ansible/credential_test.rb test/services/control_center/ansible/credential_fingerprint_test.rb`

Expected: PASS.

- [ ] **Step 7: Checkpoint**

Run: `git diff --check`

Expected: clean. With explicit commit authorization only:

```bash
git add web/Gemfile web/Gemfile.lock web/db/migrate/20260723010001_create_control_center_ansible_credentials.rb web/app/models/control_center/ansible/credential.rb web/app/models/user.rb web/app/services/control_center/ansible/credential_fingerprint.rb web/test/models/control_center/ansible/credential_test.rb web/test/services/control_center/ansible/credential_fingerprint_test.rb web/db/schema.rb
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Add encrypted Ansible SSH credentials"
```

### Task 4: Add shared write-only credential updates

**Files:**
- Create: `web/app/services/control_center/ansible/credential_updater.rb`
- Create: `web/test/services/control_center/ansible/credential_updater_test.rb`

**Interfaces:**
- Produces: `CredentialUpdater.call(credential:, attributes:) -> credential`.
- Input keys: public `name`, `auth_type`, `username`; secret fields; boolean `clear_<secret>` flags.
- Behavior: blank secret means retain, a truthy clear flag means `nil`, nonblank secret means replace.

- [ ] **Step 1: Write failing retain/replace/clear tests**

```ruby
# web/test/services/control_center/ansible/credential_updater_test.rb
require "test_helper"

class ControlCenter::Ansible::CredentialUpdaterTest < ActiveSupport::TestCase
  setup do
    @credential = ControlCenter::Ansible::Credential.create!(
      name: "workers", auth_type: "password", username: "ansible",
      ssh_password: "old", become_password: "old-sudo", created_by: users(:one)
    )
  end

  test "blank secret retains the current value" do
    update(ssh_password: "", become_password: "")
    assert_equal "old", @credential.ssh_password
    assert_equal "old-sudo", @credential.become_password
  end

  test "nonblank secret replaces and explicit clear removes" do
    update(ssh_password: "new", clear_become_password: "1")
    assert_equal "new", @credential.ssh_password
    assert_nil @credential.become_password
  end

  private

  def update(**attributes)
    ControlCenter::Ansible::CredentialUpdater.call(
      credential: @credential, attributes: attributes
    )
    @credential.save!
  end
end
```

- [ ] **Step 2: Run and verify missing service failure**

Run: `docker compose exec web bin/rails test test/services/control_center/ansible/credential_updater_test.rb`

Expected: FAIL with missing `CredentialUpdater`.

- [ ] **Step 3: Implement the updater**

```ruby
# web/app/services/control_center/ansible/credential_updater.rb
module ControlCenter
  module Ansible
    module CredentialUpdater
      PUBLIC_FIELDS = %w[name auth_type username].freeze
      SECRET_FIELDS = Credential::SECRET_FIELDS.map(&:to_s).freeze
      module_function

      def call(credential:, attributes:)
        attrs = attributes.to_h.stringify_keys
        credential.assign_attributes(attrs.slice(*PUBLIC_FIELDS))
        SECRET_FIELDS.each do |field|
          clear = ActiveModel::Type::Boolean.new.cast(attrs["clear_#{field}"])
          value = attrs[field]
          credential.public_send("#{field}=", nil) if clear
          credential.public_send("#{field}=", value) if !clear && value.present?
        end
        credential
      end
    end
  end
end
```

- [ ] **Step 4: Run tests**

Run: `docker compose exec web bin/rails test test/services/control_center/ansible/credential_updater_test.rb test/models/control_center/ansible/credential_test.rb`

Expected: PASS.

- [ ] **Step 5: Checkpoint**

Run: `git diff --check`

Expected: clean. With explicit commit authorization only:

```bash
git add web/app/services/control_center/ansible/credential_updater.rb web/test/services/control_center/ansible/credential_updater_test.rb
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Add write-only Ansible credential updates"
```

### Task 5: Add Ansible credentials to Settings

**Files:**
- Create: `web/app/controllers/settings/ansible_credentials_controller.rb`
- Create: `web/app/views/settings/_ansible_credentials.html.erb`
- Create: `web/test/integration/settings/ansible_credentials_test.rb`
- Modify: `web/config/routes.rb`
- Modify: `web/app/controllers/settings_controller.rb`
- Modify: `web/app/views/settings/show.html.erb`

**Interfaces:**
- Produces routes: `settings_ansible_credentials_path`, `settings_ansible_credential_path(id)`.
- Consumes: `CredentialUpdater.call(credential:, attributes:)`.

- [ ] **Step 1: Write failing Settings integration tests**

```ruby
# web/test/integration/settings/ansible_credentials_test.rb
require "test_helper"

class Settings::AnsibleCredentialsTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }

  test "requires authentication" do
    post settings_ansible_credentials_path, params: { ansible_credential: { name: "x" } }
    assert_redirected_to new_session_path
  end

  test "creates a password credential and never renders its value" do
    sign_in_as(@user)
    post settings_ansible_credentials_path, params: {
      ansible_credential: {
        name: "workers", auth_type: "password", username: "ansible",
        ssh_password: "never-render-me"
      }
    }
    assert_redirected_to settings_path(anchor: "ansible-credentials")
    follow_redirect!
    assert_response :success
    assert_includes response.body, "workers"
    refute_includes response.body, "never-render-me"
  end

  test "blank update retains a secret and explicit clear is validated" do
    credential = ControlCenter::Ansible::Credential.create!(
      name: "workers", auth_type: "password", username: "ansible", ssh_password: "old",
      created_by: @user
    )
    sign_in_as(@user)
    patch settings_ansible_credential_path(credential), params: {
      ansible_credential: { name: "workers", auth_type: "password", username: "ops", ssh_password: "" }
    }
    assert_redirected_to settings_path(anchor: "ansible-credentials")
    assert_equal "old", credential.reload.ssh_password
    assert_equal "ops", credential.username
  end

  test "deletes a credential" do
    credential = ControlCenter::Ansible::Credential.create!(
      name: "workers", auth_type: "password", username: "ansible", ssh_password: "old",
      created_by: @user
    )
    sign_in_as(@user)
    assert_difference -> { ControlCenter::Ansible::Credential.count }, -1 do
      delete settings_ansible_credential_path(credential)
    end
  end
end
```

- [ ] **Step 2: Run and verify route/controller failures**

Run: `docker compose exec web bin/rails test test/integration/settings/ansible_credentials_test.rb`

Expected: FAIL because the Settings credential routes do not exist.

- [ ] **Step 3: Add routes and controller**

Inside the existing `namespace :settings` block:

```ruby
    resources :ansible_credentials, only: %i[create update destroy]
```

```ruby
# web/app/controllers/settings/ansible_credentials_controller.rb
module Settings
  class AnsibleCredentialsController < ApplicationController
    def create
      credential = ::ControlCenter::Ansible::Credential.new(created_by: Current.user)
      update_from_params(credential)
      redirect_to settings_path(anchor: "ansible-credentials"), notice: "Ansible credential created."
    rescue ActiveRecord::RecordInvalid => e
      redirect_to settings_path(anchor: "ansible-credentials"), alert: e.record.errors.full_messages.to_sentence
    end

    def update
      credential = ::ControlCenter::Ansible::Credential.find(params[:id])
      update_from_params(credential)
      redirect_to settings_path(anchor: "ansible-credentials"), notice: "Ansible credential updated."
    rescue ActiveRecord::RecordInvalid => e
      redirect_to settings_path(anchor: "ansible-credentials"), alert: e.record.errors.full_messages.to_sentence
    end

    def destroy
      ::ControlCenter::Ansible::Credential.find(params[:id]).destroy!
      redirect_to settings_path(anchor: "ansible-credentials"), notice: "Ansible credential deleted."
    end

    private

    def update_from_params(credential)
      attrs = params.require(:ansible_credential).permit(
        :name, :auth_type, :username,
        :private_key, :ssh_password, :private_key_passphrase, :become_password,
        :clear_private_key, :clear_ssh_password,
        :clear_private_key_passphrase, :clear_become_password
      )
      ::ControlCenter::Ansible::CredentialUpdater.call(credential: credential, attributes: attrs)
      credential.save!
    end
  end
end
```

- [ ] **Step 4: Load and render the Settings section**

Add to `SettingsController#show`:

```ruby
    @ansible_credentials = ControlCenter::Ansible::Credential.order(:name)
```

Add the navigation link and render in `web/app/views/settings/show.html.erb`:

```erb
<a href="#ansible-credentials" class="block rounded px-2 py-1.5 text-sm text-zinc-600 hover:bg-zinc-100 dark:text-zinc-400 dark:hover:bg-zinc-800">Ansible credentials</a>
```

```erb
<%= render "settings/ansible_credentials", credentials: @ansible_credentials %>
```

Create `web/app/views/settings/_ansible_credentials.html.erb` with this complete
functional form/list shell (retain the repository's longer shared Tailwind class
strings when implementing):

```erb
<%= render layout: "settings/section", locals: {
      id: "ansible-credentials", title: "Ansible credentials",
      subtitle: "Encrypted SSH identities used by the isolated Ansible executor. Saved secrets are never shown again."
    } do %>
  <%= form_with url: settings_ansible_credentials_path, scope: :ansible_credential,
                class: "grid gap-3 rounded-lg border border-zinc-200 p-4 dark:border-zinc-800" do |f| %>
    <div class="grid gap-3 sm:grid-cols-3">
      <%= f.text_field :name, required: true, placeholder: "worker-fleet-key", class: "rounded-md border px-2 py-1.5 dark:bg-zinc-900" %>
      <%= f.select :auth_type, ControlCenter::Ansible::Credential::AUTH_TYPES.map { |v| [v.humanize, v] }, {}, class: "rounded-md border px-2 py-1.5 dark:bg-zinc-900" %>
      <%= f.text_field :username, required: true, placeholder: "ansible", class: "rounded-md border px-2 py-1.5 dark:bg-zinc-900" %>
    </div>
    <%= f.text_area :private_key, rows: 5, placeholder: "SSH private key (for private-key auth)", class: "rounded-md border px-2 py-1.5 font-mono text-xs dark:bg-zinc-900" %>
    <div class="grid gap-3 sm:grid-cols-3">
      <%= f.password_field :private_key_passphrase, placeholder: "Key passphrase", class: "rounded-md border px-2 py-1.5 dark:bg-zinc-900" %>
      <%= f.password_field :ssh_password, placeholder: "SSH password", class: "rounded-md border px-2 py-1.5 dark:bg-zinc-900" %>
      <%= f.password_field :become_password, placeholder: "Become password", class: "rounded-md border px-2 py-1.5 dark:bg-zinc-900" %>
    </div>
    <%= f.submit "Save credential", class: "w-fit rounded-md bg-zinc-900 px-3 py-1.5 text-sm text-white dark:bg-white dark:text-zinc-900" %>
  <% end %>

  <div class="mt-4 space-y-2">
    <% credentials.each do |credential| %>
      <div class="flex items-center gap-3 rounded-lg border border-zinc-200 px-3 py-2 text-sm dark:border-zinc-800">
        <div class="min-w-0 flex-1">
          <p class="font-medium"><%= credential.name %></p>
          <p class="truncate text-xs text-zinc-500"><%= credential.username %> · <%= credential.auth_type %> · <%= credential.public_key_fingerprint || "password configured" %></p>
        </div>
        <%= button_to "Delete", settings_ansible_credential_path(credential), method: :delete,
              class: "text-xs font-medium text-rose-600",
              form: { data: { turbo_confirm: "Delete #{credential.name}?" } } %>
      </div>
    <% end %>
    <p class="text-sm text-zinc-500 <%= "hidden" if credentials.any? %>">No Ansible credentials configured.</p>
  </div>
<% end %>
```

Immediately after each credential summary row, render this edit control. Secret
inputs intentionally have no `value`, and each has an explicit clear checkbox:

```erb
<details class="rounded-lg border border-zinc-200 p-3 dark:border-zinc-800">
  <summary class="cursor-pointer text-sm font-medium">Edit <%= credential.name %></summary>
  <%= form_with url: settings_ansible_credential_path(credential), method: :patch,
                scope: :ansible_credential, class: "mt-3 grid gap-3" do |f| %>
    <div class="grid gap-3 sm:grid-cols-3">
      <%= f.text_field :name, value: credential.name, required: true, class: "rounded-md border px-2 py-1.5 dark:bg-zinc-900" %>
      <%= f.select :auth_type,
            ControlCenter::Ansible::Credential::AUTH_TYPES.map { |v| [v.humanize, v] },
            { selected: credential.auth_type }, class: "rounded-md border px-2 py-1.5 dark:bg-zinc-900" %>
      <%= f.text_field :username, value: credential.username, required: true, class: "rounded-md border px-2 py-1.5 dark:bg-zinc-900" %>
    </div>
    <% ControlCenter::Ansible::Credential::SECRET_FIELDS.each do |field| %>
      <div class="grid gap-2 sm:grid-cols-[1fr_auto] sm:items-center">
        <% if field == :private_key %>
          <%= f.text_area field, value: nil, rows: 4,
                placeholder: credential.public_send("#{field}_configured?") ? "Configured — leave blank to retain" : "Not configured",
                autocomplete: "off", class: "rounded-md border px-2 py-1.5 font-mono text-xs dark:bg-zinc-900" %>
        <% else %>
          <%= f.password_field field, value: nil,
                placeholder: credential.public_send("#{field}_configured?") ? "Configured — leave blank to retain" : "Not configured",
                autocomplete: "new-password", class: "rounded-md border px-2 py-1.5 dark:bg-zinc-900" %>
        <% end %>
        <label class="flex items-center gap-2 text-xs text-zinc-600 dark:text-zinc-400">
          <%= f.check_box "clear_#{field}" %> Clear saved <%= field.to_s.humanize.downcase %>
        </label>
      </div>
    <% end %>
    <%= f.submit "Update credential", class: "w-fit rounded-md bg-zinc-900 px-3 py-1.5 text-sm text-white dark:bg-white dark:text-zinc-900" %>
  <% end %>
</details>
```

- [ ] **Step 5: Run Settings tests**

Run: `docker compose exec web bin/rails test test/integration/settings/ansible_credentials_test.rb test/integration/settings/config_test.rb test/integration/settings_test.rb`

Expected: PASS.

- [ ] **Step 6: Checkpoint**

Run: `git diff --check`

Expected: clean. With explicit commit authorization only:

```bash
git add web/config/routes.rb web/app/controllers/settings_controller.rb web/app/controllers/settings/ansible_credentials_controller.rb web/app/views/settings/show.html.erb web/app/views/settings/_ansible_credentials.html.erb web/test/integration/settings/ansible_credentials_test.rb
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Add encrypted Ansible credentials to Settings"
```

### Task 6: Add write-only credential JSON CRUD and OpenAPI docs

**Files:**
- Create: `web/app/controllers/api/v1/control_center/ansible/credentials_controller.rb`
- Create: `web/test/integration/api/v1/control_center/ansible/credentials_test.rb`
- Modify: `web/config/routes.rb`
- Modify: `web/config/openapi/control_center.yaml`

**Interfaces:**
- Produces: `/api/v1/control_center/ansible/credentials` CRUD.
- JSON credential shape: `id`, `name`, `auth_type`, `username`, `public_key_fingerprint`, four `*_configured` booleans, `last_used_at`, timestamps.
- No JSON response contains `private_key`, `ssh_password`, `private_key_passphrase`, or `become_password`.

- [ ] **Step 1: Write failing API integration tests**

```ruby
# web/test/integration/api/v1/control_center/ansible/credentials_test.rb
require "test_helper"

class Api::V1::ControlCenter::Ansible::CredentialsTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }

  test "requires authentication" do
    get "/api/v1/control_center/ansible/credentials"
    assert_response :unauthorized
  end

  test "creates and serializes only metadata" do
    sign_in_as(@user)
    post "/api/v1/control_center/ansible/credentials", params: {
      name: "workers", auth_type: "password", username: "ansible",
      ssh_password: "api-secret", become_password: "sudo-secret"
    }, as: :json
    assert_response :created
    body = JSON.parse(response.body)
    assert_equal true, body["ssh_password_configured"]
    assert_equal true, body["become_password_configured"]
    refute body.key?("ssh_password")
    refute_includes response.body, "api-secret"
    refute_includes response.body, "sudo-secret"
  end

  test "blank update retains the secret" do
    credential = ControlCenter::Ansible::Credential.create!(
      name: "workers", auth_type: "password", username: "a", ssh_password: "old",
      created_by: @user
    )
    sign_in_as(@user)
    patch "/api/v1/control_center/ansible/credentials/#{credential.id}",
          params: { username: "b", ssh_password: "" }, as: :json
    assert_response :success
    assert_equal "old", credential.reload.ssh_password
  end

  test "control-center-scoped bearer may list credentials without secrets" do
    _token, raw = ApiToken.generate(user: @user, name: "cc", scopes: ["control_center"])
    get "/api/v1/control_center/ansible/credentials", headers: { "Authorization" => "Bearer #{raw}" }
    assert_response :success
  end

  test "wrong bearer scope is forbidden" do
    _token, raw = ApiToken.generate(user: @user, name: "cves", scopes: ["cves"])
    get "/api/v1/control_center/ansible/credentials", headers: { "Authorization" => "Bearer #{raw}" }
    assert_response :forbidden
  end
end
```

- [ ] **Step 2: Run and verify missing route/controller failures**

Run: `docker compose exec web bin/rails test test/integration/api/v1/control_center/ansible/credentials_test.rb`

Expected: FAIL with routing errors.

- [ ] **Step 3: Add routes and controller**

Inside `api/v1/control_center` in `web/config/routes.rb`:

```ruby
        namespace :ansible do
          resources :credentials, only: %i[index show create update destroy]
        end
```

```ruby
# web/app/controllers/api/v1/control_center/ansible/credentials_controller.rb
module Api
  module V1
    module ControlCenter
      module Ansible
        class CredentialsController < Api::V1::BaseController
          api_scope :control_center

          def index
            render json: { credentials: scope.map { |credential| serialize(credential) } }
          end

          def show
            credential = scope.find_by(id: params[:id])
            return render_not_found unless credential
            render json: serialize(credential)
          end

          def create
            credential = ::ControlCenter::Ansible::Credential.new(created_by: Current.user)
            persist(credential, status: :created)
          end

          def update
            credential = scope.find_by(id: params[:id])
            return render_not_found unless credential
            persist(credential)
          end

          def destroy
            credential = scope.find_by(id: params[:id])
            return render_not_found unless credential
            credential.destroy!
            head :no_content
          end

          private

          def scope
            ::ControlCenter::Ansible::Credential.order(:name)
          end

          def persist(credential, status: :ok)
            ::ControlCenter::Ansible::CredentialUpdater.call(
              credential: credential,
              attributes: params.permit(
                :name, :auth_type, :username,
                :private_key, :ssh_password, :private_key_passphrase, :become_password,
                :clear_private_key, :clear_ssh_password,
                :clear_private_key_passphrase, :clear_become_password
              )
            )
            if credential.save
              render json: serialize(credential), status: status
            else
              render json: { error: "unprocessable_entity", detail: credential.errors.full_messages }, status: :unprocessable_entity
            end
          end

          def serialize(credential)
            {
              id: credential.id,
              name: credential.name,
              auth_type: credential.auth_type,
              username: credential.username,
              public_key_fingerprint: credential.public_key_fingerprint,
              private_key_configured: credential.private_key_configured?,
              ssh_password_configured: credential.ssh_password_configured?,
              private_key_passphrase_configured: credential.private_key_passphrase_configured?,
              become_password_configured: credential.become_password_configured?,
              last_used_at: credential.last_used_at,
              created_at: credential.created_at,
              updated_at: credential.updated_at
            }
          end
        end
      end
    end
  end
end
```

- [ ] **Step 4: Document the credential endpoints**

Add these path entries to `web/config/openapi/control_center.yaml` (the PUT alias
may reference the same request/response schema as PATCH):

```yaml
  /api/v1/control_center/ansible/credentials:
    get:
      tags: ["Control Center / Ansible"]
      x-api-scope: control_center
      summary: "List Ansible credential metadata"
      responses:
        "200":
          description: "Credential metadata without secret values."
          content: { application/json: { schema: { type: object, properties: { credentials: { type: array, items: { $ref: "#/components/schemas/CcAnsibleCredential" } } }, required: [credentials] } } }
        "401": { $ref: "#/components/responses/Unauthorized" }
        "403": { $ref: "#/components/responses/InsufficientScope" }
    post:
      tags: ["Control Center / Ansible"]
      x-api-scope: control_center
      summary: "Create an encrypted Ansible credential"
      requestBody: { required: true, content: { application/json: { schema: { $ref: "#/components/schemas/CcAnsibleCredentialInput" } } } }
      responses:
        "201": { description: "Created.", content: { application/json: { schema: { $ref: "#/components/schemas/CcAnsibleCredential" } } } }
        "401": { $ref: "#/components/responses/Unauthorized" }
        "403": { $ref: "#/components/responses/InsufficientScope" }
        "422": { $ref: "#/components/responses/CcUnprocessable" }
  /api/v1/control_center/ansible/credentials/{id}:
    parameters:
      - { name: id, in: path, required: true, schema: { type: integer } }
    get:
      tags: ["Control Center / Ansible"]
      x-api-scope: control_center
      summary: "Get Ansible credential metadata"
      responses:
        "200": { description: "Credential metadata.", content: { application/json: { schema: { $ref: "#/components/schemas/CcAnsibleCredential" } } } }
        "401": { $ref: "#/components/responses/Unauthorized" }
        "403": { $ref: "#/components/responses/InsufficientScope" }
        "404": { $ref: "#/components/responses/NotFound" }
    patch:
      tags: ["Control Center / Ansible"]
      x-api-scope: control_center
      summary: "Update an encrypted Ansible credential"
      requestBody: { required: true, content: { application/json: { schema: { $ref: "#/components/schemas/CcAnsibleCredentialInput" } } } }
      responses:
        "200": { description: "Updated.", content: { application/json: { schema: { $ref: "#/components/schemas/CcAnsibleCredential" } } } }
        "401": { $ref: "#/components/responses/Unauthorized" }
        "403": { $ref: "#/components/responses/InsufficientScope" }
        "404": { $ref: "#/components/responses/NotFound" }
        "422": { $ref: "#/components/responses/CcUnprocessable" }
    delete:
      tags: ["Control Center / Ansible"]
      x-api-scope: control_center
      summary: "Delete an Ansible credential"
      responses:
        "204": { description: "Deleted." }
        "401": { $ref: "#/components/responses/Unauthorized" }
        "403": { $ref: "#/components/responses/InsufficientScope" }
        "404": { $ref: "#/components/responses/NotFound" }
```

Add these schemas under `components.schemas`:

```yaml
    CcAnsibleCredential:
      type: object
      properties:
        id: { type: integer }
        name: { type: string }
        auth_type: { type: string, enum: [private_key, password] }
        username: { type: string }
        public_key_fingerprint: { type: [string, "null"] }
        private_key_configured: { type: boolean }
        ssh_password_configured: { type: boolean }
        private_key_passphrase_configured: { type: boolean }
        become_password_configured: { type: boolean }
        last_used_at: { type: [string, "null"], format: date-time }
        created_at: { type: string, format: date-time }
        updated_at: { type: string, format: date-time }
      required: [id, name, auth_type, username, private_key_configured, ssh_password_configured, private_key_passphrase_configured, become_password_configured]
    CcAnsibleCredentialInput:
      type: object
      properties:
        name: { type: string }
        auth_type: { type: string, enum: [private_key, password] }
        username: { type: string }
        private_key: { type: string, writeOnly: true }
        ssh_password: { type: string, writeOnly: true }
        private_key_passphrase: { type: string, writeOnly: true }
        become_password: { type: string, writeOnly: true }
        clear_private_key: { type: boolean, default: false }
        clear_ssh_password: { type: boolean, default: false }
        clear_private_key_passphrase: { type: boolean, default: false }
        clear_become_password: { type: boolean, default: false }
      required: [name, auth_type, username]
```

Responses use only `CcAnsibleCredential`; the four secret properties exist only
in the write schema.

- [ ] **Step 5: Run API and OpenAPI tests**

Run: `docker compose exec web bin/rails test test/integration/api/v1/control_center/ansible/credentials_test.rb test/services/api_docs/spec_test.rb test/integration/api/v1/openapi_test.rb`

Expected: PASS.

- [ ] **Step 6: Run foundation regression suite**

Run: `docker compose exec web bin/rails test test/config/active_record_encryption_test.rb test/models/control_center/ansible test/services/control_center/ansible test/integration/settings test/integration/api/v1/control_center/ansible test/models/runner_test.rb test/integration/api/runner/jobs_test.rb`

Expected: PASS.

Run: `docker compose exec web bin/rails test`

Expected: full Rails suite PASS.

- [ ] **Step 7: Checkpoint**

Run: `git diff --check && git status --short`

Expected: only the planned foundation files plus preserved unrelated contributor
changes. With explicit commit authorization only:

```bash
git add web/config/routes.rb web/app/controllers/api/v1/control_center/ansible/credentials_controller.rb web/test/integration/api/v1/control_center/ansible/credentials_test.rb web/config/openapi/control_center.yaml
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Expose write-only Ansible credential management"
```
