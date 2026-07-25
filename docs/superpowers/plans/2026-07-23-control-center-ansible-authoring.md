# Control Center Ansible Authoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the Ansible Control Center tab for raw YAML playbook and inventory authoring, reusable encrypted variable sets, validation, and single/bulk playbook import and export.

**Architecture:** PostgreSQL is the source of truth for Ansible authoring records. Small safe-YAML services enforce resource limits and reject connection secrets, vault/custom tags, and explicit local execution before persistence. Rails APIs own CRUD and ZIP generation; Stimulus owns draft-only file reads, sequential multi-file imports, conflict decisions, and selection state. This plan depends on the encryption and credentials foundation plan and deliberately does not execute Ansible.

**Tech Stack:** Ruby 3.3.6, Rails 8.1, PostgreSQL, Active Record Encryption, Psych safe loading, rubyzip, Hotwire/Stimulus, importmap, Minitest, Node's built-in test runner for DOM-independent JavaScript.

## Global Constraints

- Complete `2026-07-23-control-center-ansible-foundation.md` first.
- Preserve all unrelated worktree changes; another contributor owns the Whiterabbit bulk-import files.
- Do not share the Whiterabbit importer implementation. Reuse only its settled interaction conventions.
- Label the persistent bulk action **Import YAML** and the selected ZIP action **Download selected** consistently in views and tests.
- All API controllers subclass `Api::V1::BaseController` and declare `api_scope :control_center`.
- Playbook and inventory YAML are never encrypted, so every editor and export surface must warn against embedded secrets.
- Every managed variable value is non-deterministically encrypted; the `secret` flag controls read masking and output redaction only.
- No custom YAML tags, Vault input, local connection, `local_action`, localhost delegation, or connection-secret variables are accepted.
- Do not commit unless the user explicitly authorizes it.

## New files

- `web/db/migrate/20260723020001_create_control_center_ansible_authoring.rb`
- `web/app/models/control_center/ansible/playbook.rb`
- `web/app/models/control_center/ansible/inventory.rb`
- `web/app/models/control_center/ansible/variable_set.rb`
- `web/app/models/control_center/ansible/variable.rb`
- `web/app/models/control_center/ansible/playbook_variable_set.rb`
- `web/app/models/control_center/ansible/inventory_variable_set.rb`
- `web/app/services/control_center/ansible/yaml_limits.rb`
- `web/app/services/control_center/ansible/yaml_document.rb`
- `web/app/services/control_center/ansible/playbook_validator.rb`
- `web/app/services/control_center/ansible/inventory_validator.rb`
- `web/app/services/control_center/ansible/typed_value.rb`
- `web/app/services/control_center/ansible/variable_resolver.rb`
- `web/app/services/control_center/ansible/playbook_archive.rb`
- `web/test/models/control_center/ansible/playbook_test.rb`
- `web/test/models/control_center/ansible/inventory_test.rb`
- `web/test/models/control_center/ansible/variable_set_test.rb`
- `web/test/models/control_center/ansible/variable_test.rb`
- `web/test/models/control_center/ansible/playbook_variable_set_test.rb`
- `web/test/models/control_center/ansible/inventory_variable_set_test.rb`
- `web/test/services/control_center/ansible/yaml_document_test.rb`
- `web/test/services/control_center/ansible/playbook_validator_test.rb`
- `web/test/services/control_center/ansible/inventory_validator_test.rb`
- `web/test/services/control_center/ansible/typed_value_test.rb`
- `web/test/services/control_center/ansible/variable_resolver_test.rb`
- `web/test/services/control_center/ansible/playbook_archive_test.rb`
- `web/app/controllers/api/v1/control_center/ansible/playbooks_controller.rb`
- `web/app/controllers/api/v1/control_center/ansible/inventories_controller.rb`
- `web/app/controllers/api/v1/control_center/ansible/variable_sets_controller.rb`
- `web/app/controllers/api/v1/control_center/ansible/variables_controller.rb`
- `web/test/integration/api/v1/control_center/ansible/playbooks_test.rb`
- `web/test/integration/api/v1/control_center/ansible/inventories_test.rb`
- `web/test/integration/api/v1/control_center/ansible/variable_sets_test.rb`
- `web/app/controllers/control_center/ansible/base_controller.rb`
- `web/app/controllers/control_center/ansible/playbooks_controller.rb`
- `web/app/controllers/control_center/ansible/inventories_controller.rb`
- `web/app/controllers/control_center/ansible/variable_sets_controller.rb`
- `web/app/controllers/control_center/ansible/runs_controller.rb`
- `web/app/views/control_center/ansible/_navigation.html.erb`
- `web/app/views/control_center/ansible/playbooks/index.html.erb`
- `web/app/views/control_center/ansible/inventories/index.html.erb`
- `web/app/views/control_center/ansible/variable_sets/index.html.erb`
- `web/app/views/control_center/ansible/runs/index.html.erb`
- `web/test/integration/control_center/ansible/navigation_test.rb`
- `web/test/integration/control_center/ansible/playbooks_test.rb`
- `web/test/integration/control_center/ansible/inventories_test.rb`
- `web/test/integration/control_center/ansible/variable_sets_test.rb`
- `web/app/javascript/controllers/ansible_authoring_controller.js`
- `web/app/javascript/controllers/ansible_playbook_import_controller.js`
- `web/app/javascript/controllers/ansible_playbook_selection_controller.js`
- `web/app/javascript/lib/ansible_playbook_batch_importer.js`
- `web/test/javascript/ansible_authoring_test.mjs`
- `web/test/javascript/ansible_playbook_batch_importer_test.mjs`
- `web/test/javascript/ansible_playbook_selection_test.mjs`

## Modified files

- `web/app/models/user.rb`
- `web/app/controllers/control_center/base_controller.rb`
- `web/config/routes.rb`
- `web/config/openapi/control_center.yaml`
- `web/app/helpers/icon_helper.rb` only if a required icon is still absent after the concurrent branch settles

---

### Task 1: Persist authoring resources and encrypted variables

**Files:** migration and six models listed above; `web/app/models/user.rb`; corresponding model tests.

**Interfaces:**

- `Playbook#yaml_content`, `Inventory#yaml_content`, and their SHA-256 `checksum` values.
- `Variable#typed_value` and `Variable#typed_value=(value)`.
- Ordered default variable-set joins scoped uniquely by owner and variable set.

- [ ] **Step 1: Write failing association, ordering, uniqueness, and ciphertext tests**

Create model tests that assert:

```ruby
playbook = ControlCenter::Ansible::Playbook.create!(
  name: "Baseline", yaml_content: "---\n- hosts: workers\n  tasks: []\n", created_by: users(:one)
)
assert_equal Digest::SHA256.hexdigest(playbook.yaml_content), playbook.checksum

set = ControlCenter::Ansible::VariableSet.create!(name: "Production", created_by: users(:one))
variable = set.variables.create!(name: "deploy_port", value_type: "number", serialized_value: "8443", position: 1)
assert_equal 8443, variable.typed_value
raw = ActiveRecord::Base.connection.select_value(
  "SELECT serialized_value FROM control_center_ansible_variables WHERE id = #{variable.id.to_i}"
)
refute_includes raw, "8443"

set.variables.create!(name: "feature_enabled", value_type: "boolean", serialized_value: "true", position: 2)
assert_raises(ActiveRecord::RecordInvalid) do
  set.variables.create!(name: "deploy_port", value_type: "string", serialized_value: "duplicate", position: 3)
end
```

- [ ] **Step 2: Run the tests and confirm missing-table/model failures**

Run: `docker compose exec web bin/rails test test/models/control_center/ansible`

Expected: FAIL because the authoring tables and models do not exist.

- [ ] **Step 3: Create the schema**

Use this migration shape:

```ruby
class CreateControlCenterAnsibleAuthoring < ActiveRecord::Migration[8.1]
  def change
    create_table :control_center_ansible_playbooks do |t|
      t.string :name, null: false
      t.text :description
      t.text :yaml_content, null: false
      t.string :checksum, null: false
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.timestamps
    end
    add_index :control_center_ansible_playbooks, "lower(name)", unique: true,
      name: "idx_ansible_playbooks_lower_name"

    create_table :control_center_ansible_inventories do |t|
      t.string :name, null: false
      t.text :description
      t.text :yaml_content, null: false
      t.string :checksum, null: false
      t.references :default_credential, foreign_key: { to_table: :control_center_ansible_credentials }
      t.text :known_hosts
      t.jsonb :host_key_fingerprints, null: false, default: {}
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.timestamps
    end
    add_index :control_center_ansible_inventories, "lower(name)", unique: true,
      name: "idx_ansible_inventories_lower_name"

    create_table :control_center_ansible_variable_sets do |t|
      t.string :name, null: false
      t.text :description
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.timestamps
    end
    add_index :control_center_ansible_variable_sets, "lower(name)", unique: true,
      name: "idx_ansible_variable_sets_lower_name"

    create_table :control_center_ansible_variables do |t|
      t.references :variable_set, null: false,
        foreign_key: { to_table: :control_center_ansible_variable_sets }
      t.string :name, null: false
      t.string :value_type, null: false
      t.text :serialized_value, null: false
      t.boolean :secret, null: false, default: false
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :control_center_ansible_variables, %i[variable_set_id name], unique: true,
      name: "idx_ansible_variables_set_name"
    add_index :control_center_ansible_variables, %i[variable_set_id position],
      name: "idx_ansible_variables_set_position"

    create_table :control_center_ansible_playbook_variable_sets do |t|
      t.references :playbook, null: false,
        foreign_key: { to_table: :control_center_ansible_playbooks }
      t.references :variable_set, null: false,
        foreign_key: { to_table: :control_center_ansible_variable_sets }
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :control_center_ansible_playbook_variable_sets,
      %i[playbook_id variable_set_id], unique: true, name: "idx_ansible_playbook_variable_sets_unique"

    create_table :control_center_ansible_inventory_variable_sets do |t|
      t.references :inventory, null: false,
        foreign_key: { to_table: :control_center_ansible_inventories }
      t.references :variable_set, null: false,
        foreign_key: { to_table: :control_center_ansible_variable_sets }
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :control_center_ansible_inventory_variable_sets,
      %i[inventory_id variable_set_id], unique: true, name: "idx_ansible_inventory_variable_sets_unique"
  end
end
```

- [ ] **Step 4: Implement the models**

All three named resources use `before_validation :normalize_name` and case-insensitive uniqueness. Playbook and inventory use:

```ruby
before_validation :set_checksum
validates :name, presence: true, uniqueness: { case_sensitive: false }
validates :yaml_content, presence: true

def set_checksum
  self.checksum = Digest::SHA256.hexdigest(yaml_content.to_s)
end
```

`Variable` uses:

```ruby
VALUE_TYPES = %w[string number boolean list dictionary].freeze
encrypts :serialized_value
belongs_to :variable_set, class_name: "ControlCenter::Ansible::VariableSet"
validates :name, presence: true,
  format: { with: /\A[A-Za-z_][A-Za-z0-9_]*\z/ },
  uniqueness: { scope: :variable_set_id }
validates :value_type, inclusion: { in: VALUE_TYPES }
validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
validate :serialized_value_is_typed

def typed_value
  ControlCenter::Ansible::TypedValue.load(serialized_value, type: value_type)
end

def typed_value=(value)
  self.serialized_value = ControlCenter::Ansible::TypedValue.dump(value, type: value_type)
end
```

Configure `dependent: :destroy` for owned variables/joins, `dependent: :nullify` for an inventory's default credential, and `-> { order(:position, :id) }` on ordered associations. Add user `has_many` associations with `foreign_key: :created_by_id` and no broad dependent deletion.

- [ ] **Step 5: Migrate and verify**

Run:

```bash
docker compose exec web bin/rails db:migrate
docker compose exec web bin/rails test test/models/control_center/ansible
```

Expected: PASS.

### Task 2: Add bounded safe-YAML and resource-specific validators

**Files:** `yaml_limits.rb`, `yaml_document.rb`, `playbook_validator.rb`, `inventory_validator.rb`, and service tests.

**Interfaces:**

```ruby
Result = Data.define(:document, :errors) do
  def valid? = errors.empty?
end
PlaybookValidator.call(yaml) # => Result
InventoryValidator.call(yaml) # => Result
```

Constants: `MAX_BYTES = 256.kilobytes`, `MAX_DEPTH = 30`, `MAX_NODES = 10_000`.

- [ ] **Step 1: Write the validator matrix first**

Cover valid playbooks/inventories plus exact rejections for: oversized input, aliases, custom tags, `!vault`, scalar roots, excessive depth/node count, `connection: local`, `ansible_connection: local`, `local_action`, `delegate_to: localhost`, embedded PEM blocks, and these case-insensitive keys anywhere in either resource:

```ruby
RESERVED_CONNECTION_KEYS = %w[
  ansible_password ansible_ssh_pass ansible_become_password ansible_become_pass
  ansible_private_key_file ansible_ssh_private_key_file ansible_user ansible_ssh_user
].freeze
```

Inventory tests additionally accept aliases, `ansible_host`, and integer ports, but reject malformed ports and a root other than a mapping.

- [ ] **Step 2: Confirm tests fail**

Run: `docker compose exec web bin/rails test test/services/control_center/ansible/yaml_document_test.rb test/services/control_center/ansible/playbook_validator_test.rb test/services/control_center/ansible/inventory_validator_test.rb`

Expected: FAIL because the services are absent.

- [ ] **Step 3: Implement one safe parsing boundary**

`YamlDocument.call` must check bytes before parsing, use `Psych.safe_load(yaml, permitted_classes: [], permitted_symbols: [], aliases: false)`, walk only Array/Hash nodes with an explicit stack, and return stable messages rather than raising `Psych::Exception`. Before safe loading, inspect `Psych.parse_stream` and reject every non-standard tag and any scalar containing `ANSIBLE_VAULT` or a PEM boundary. Normalize keys to strings only for inspection; preserve the parsed document.

`PlaybookValidator` requires a non-empty Array of Hash plays, a non-blank `hosts`, and Array-valued task sections when present. Recursively inspect task dictionaries, including `block`, `rescue`, and `always`, for prohibited keys/values. `InventoryValidator` requires a Hash and recursively validates `hosts`, `children`, and `vars` shapes. Both return all validation messages in deterministic traversal order.

- [ ] **Step 4: Connect model validation to the services**

Add to `Playbook` and `Inventory`:

```ruby
validate :yaml_is_safe

def yaml_is_safe
  result = self.class::VALIDATOR.call(yaml_content.to_s)
  result.errors.each { |message| errors.add(:yaml_content, message) }
end
```

Set `Playbook::VALIDATOR = ControlCenter::Ansible::PlaybookValidator` and the inventory equivalent. Re-run model and service tests; expect PASS.

### Task 3: Implement typed values and deterministic variable resolution

**Files:** `typed_value.rb`, `variable_resolver.rb`, tests.

**Interfaces:**

```ruby
TypedValue.load(serialized, type:) # Ruby scalar/Array/Hash
TypedValue.dump(value, type:)      # normalized JSON string
VariableResolver.call(inventory:, playbooks:, launch_sets:, overrides:)
# => Result.new(values:, secret_values:, audit_values:, secret_names:, errors:)
```

- [ ] **Step 1: Write failing type and precedence tests**

Test exact string preservation; JSON-compatible finite numbers; `true`/`false` only; safe list/dictionary fragments; no symbols, tags, aliases, non-string dictionary keys, NaN, or infinity. Test precedence in this order: inventory-attached sets, playbook-attached sets, launch sets, overrides. Duplicates at the same level must return an error naming the duplicate; higher levels intentionally replace lower levels. Secret audit data contains the name but not the value.

- [ ] **Step 2: Implement normalized typed serialization**

Use `JSON.generate` as the stored canonical representation for every type. `load` parses JSON and validates the result against `value_type`; string input is encoded as a JSON string by `dump`. Arrays and dictionaries accept safe YAML or JSON at the form/API boundary, normalize recursively to JSON primitives, and enforce depth 20 and 2,000 nodes.

- [ ] **Step 3: Implement the resolver without Active Record writes**

Resolve ordered sources into a plain Hash, tracking source level and secret status. For each level, build a temporary name map, emit errors for duplicates, then merge only if the level is valid. Return `secret_values` as the exact non-empty strings used later by redaction; return `audit_values` only for non-secret values and `secret_names` for secret keys.

- [ ] **Step 4: Run focused tests**

Run: `docker compose exec web bin/rails test test/services/control_center/ansible/typed_value_test.rb test/services/control_center/ansible/variable_resolver_test.rb test/models/control_center/ansible/variable_test.rb`

Expected: PASS with ciphertext assertions intact.

### Task 4: Add scoped CRUD and fast-validation APIs

**Files:** Ansible API controllers, `web/config/routes.rb`, API integration tests, `web/config/openapi/control_center.yaml`.

**Routes:**

```ruby
namespace :ansible do
  resources :playbooks do
    post :validate, on: :collection
    post :export, on: :collection
  end
  resources :inventories do
    post :validate, on: :collection
  end
  resources :variable_sets do
    resources :variables, only: %i[create update destroy]
  end
end
```

This block belongs inside `namespace :api do / namespace :v1 do / namespace :control_center do`.

- [ ] **Step 1: Write API tests before controllers**

For every resource, cover unauthenticated `401`, bearer tokens without `control_center` scope receiving `403`, session CRUD, bearer CRUD, `404`, and `422`. Assert playbook/inventory payloads include `id`, `name`, `description`, `yaml_content`, `checksum`, attached variable-set IDs, and timestamps. Assert variables serialize as:

```json
{"id":7,"name":"api_token","value_type":"string","secret":true,"configured":true,"value":null,"position":0}
```

For a non-secret variable, `value` contains the typed value. On update, missing/blank `value` retains a secret; `clear_value: true` is rejected unless a replacement is supplied because variables cannot persist without values.

- [ ] **Step 2: Run API tests and observe route/controller failures**

Run: `docker compose exec web bin/rails test test/integration/api/v1/control_center/ansible`

Expected: FAIL with missing routes/controllers.

- [ ] **Step 3: Implement thin controllers and strong parameters**

Each controller starts with:

```ruby
class Api::V1::ControlCenter::Ansible::PlaybooksController < Api::V1::BaseController
  api_scope :control_center
end
```

Scope index ordering by `lower(name), id`. Assign `created_by: Current.user` server-side. Use model errors for `422`:

```ruby
render json: { error: "unprocessable_entity", details: record.errors.to_hash },
  status: :unprocessable_entity
```

Never permit `created_by_id`, encrypted columns, checksum, known-host fields, or credential secret aliases. Validation actions instantiate an unsaved resource from only `yaml_content` and return `{ valid: Boolean, errors: Array<String> }` without persisting it. Variable replacement uses a dedicated form method that applies `value_type` before serializing `value` and leaves an existing secret untouched if `value` is absent.

- [ ] **Step 4: Document exact OpenAPI operations in the existing Control Center fragment**

Add all paths above to `web/config/openapi/control_center.yaml` with `control_center` scope metadata. Define reusable schemas `AnsiblePlaybook`, `AnsibleInventory`, `AnsibleVariableSet`, `AnsibleVariable`, `AnsibleValidationResult`, and `ValidationError`. Mark `value` nullable/read-only when `secret` and ensure no schema contains `private_key`, `ssh_password`, `private_key_passphrase`, or `become_password` outside the credential write schema from the foundation plan.

- [ ] **Step 5: Verify APIs and OpenAPI assembly**

Run:

```bash
docker compose exec web bin/rails test test/integration/api/v1/control_center/ansible
docker compose exec web bin/rails test test/integration/api/v1/openapi_test.rb
```

Expected: PASS.

### Task 5: Add the Ansible tab and authoring shells

**Files:** `base_controller.rb`, Ansible web controllers/views, routes, integration tests.

**Web routes:**

```ruby
namespace :control_center do
  namespace :ansible do
    get "/", to: "playbooks#index", as: :root
    resources :playbooks, only: :index
    resources :inventories, only: :index
    resources :variable_sets, only: :index
    resources :runs, only: %i[index show]
  end
end
```

- [ ] **Step 1: Write markup/navigation integration tests**

Assert the Control Center tab list includes a single Ansible link; every Ansible page renders secondary links for Playbooks, Inventories, Variable Sets, and Runs; active-state attributes are correct; unauthenticated requests redirect through existing auth; and each editor root carries only endpoint URLs and configured byte/file limits as Stimulus values—never secrets.

- [ ] **Step 2: Add the department tab and secondary navigation**

Append to `ControlCenter::BaseController::TABS`:

```ruby
{ name: "Ansible", path: :control_center_ansible_root_path }
```

Create `ControlCenter::Ansible::BaseController < ControlCenter::BaseController`, four thin controllers, and `_navigation.html.erb`. The Runs page is an explicit empty state saying execution will be enabled by the next delivery plan; do not create fake run controls.

- [ ] **Step 3: Build accessible server-rendered shells**

Playbooks and Inventories use a responsive two-column list/editor with `<textarea spellcheck="false">`, search, resource actions, validation region with `aria-live="polite"`, dirty-state indicator, and persistent raw-YAML secret warning. Variable Sets use a list plus ordered rows for name, type, secret toggle, write-only value, and move/delete actions. All user-supplied content initially appears in text nodes/form values; do not inject HTML.

- [ ] **Step 4: Run web integration tests**

Run: `docker compose exec web bin/rails test test/integration/control_center/ansible`

Expected: PASS.

### Task 6: Implement draft editing and single-file upload/download

**Files:** `ansible_authoring_controller.js`, views, JS tests.

**Stimulus contract:** targets `list`, `form`, `name`, `description`, `yaml`, `validation`, `dirty`, `uploadInput`; values `indexUrl`, `validateUrl`, `resourceType`, `maxBytes`.

- [ ] **Step 1: Write DOM-independent helper tests**

Extract pure functions from the controller and test filename acceptance (`.yml`/`.yaml`, case-insensitive), sanitized download names, byte limits using `Blob#size`, dirty transitions, and server-error normalization. Run with:

`node --test web/test/javascript/ansible_authoring_test.mjs`

Expected: FAIL until the module exists.

- [ ] **Step 2: Implement CRUD hydration and validation**

Use the existing `api_fetch.js` wrapper for JSON. New/save/delete update the local list only after a successful API response. Validate posts `{ yaml_content }`, renders every returned message with `textContent`, and never changes persistence. Unsaved navigation requires an explicit discard confirmation.

- [ ] **Step 3: Implement single-file actions locally**

Upload accepts exactly one YAML file, checks extension/size before `file.text()`, and places it into the editor without saving. Download creates a Blob from the current textarea contents, a temporary object URL, and a sanitized `<name>.yml`; revoke the URL immediately after the click. It does not call the server and may download an unsaved draft.

- [ ] **Step 4: Run JS and markup tests**

Run:

```bash
node --test web/test/javascript/ansible_authoring_test.mjs
docker compose exec web bin/rails test test/integration/control_center/ansible
```

Expected: PASS.

### Task 7: Implement sequential bulk import with conflict policies

**Files:** `ansible_playbook_batch_importer.js`, `ansible_playbook_import_controller.js`, playbooks view, JS tests.

**Pure importer interface:**

```javascript
new AnsiblePlaybookBatchImporter({
  validateFile,
  validateYaml,
  findByName,
  createPlaybook,
  updatePlaybook,
  resolveConflict,
  limits: { maxFiles: 100, maxFileBytes: 262144, maxBatchBytes: 10485760 }
}).run(files, onProgress)
```

- [ ] **Step 1: Write the complete state-machine test matrix**

Using `node:test`, cover extension case, file/batch/count limits, filename-derived names, duplicate derived names, validation failures, independent continuation, Update, Update all, Skip, Skip all, later-file-wins for duplicate updates, thrown network errors, and summary counts for `imported`, `updated`, `skipped`, and `failed`. Assert files are processed sequentially by recording callback order.

- [ ] **Step 2: Implement the pure importer**

Normalize names by stripping only the final `.yml`/`.yaml`, replacing runs outside `[A-Za-z0-9._-]` with `-`, trimming separators, and rejecting an empty result. Keep `updateAll`/`skipAll` local to one `run`. Emit immutable per-file progress records with states `waiting`, `validating`, `imported`, `updated`, `skipped`, or `failed`. Never put YAML content into error strings.

- [ ] **Step 3: Connect picker and stable drag/drop overlay**

The Stimulus controller owns a drag-depth counter so child enter/leave events do not flicker the overlay. Filter dropped/picked files through the same importer. The modal lists filenames and status via `textContent`, traps focus while conflict resolution is open, and resets batch-wide choices after completion. Refresh the playbook index once at batch completion, not after each file.

- [ ] **Step 4: Verify**

Run: `node --test web/test/javascript/ansible_playbook_batch_importer_test.mjs`

Expected: PASS.

### Task 8: Implement bounded selected ZIP export

**Files:** `playbook_archive.rb`, API playbooks controller, selection controller, tests.

**Interface:**

```ruby
archive = ControlCenter::Ansible::PlaybookArchive.call(playbooks)
archive.path      # Tempfile path while open
archive.filename  # "hunter-ansible-playbooks-20260723T120000Z.zip"
archive.close!    # closes and unlinks
```

- [ ] **Step 1: Write archive and endpoint tests**

Assert an empty or over-limit selection returns `422`; unknown IDs return `404`; IDs are deduplicated; files contain exact saved YAML; filenames are sanitized, deterministic by selected order, and collision-suffixed (`baseline.yml`, `baseline-2.yml`); ZIP contains no server path, variable, credential, or run data; response type is `application/zip`; cookie requests require CSRF; scoped bearer requests work; Tempfile is unlinked after body completion.

- [ ] **Step 2: Implement archive generation**

Use the existing `rubyzip` dependency and a binary `Tempfile`. Add entries from memory, never filesystem paths. Limit selection to 100 and total uncompressed YAML to 10 MiB. The service closes and deletes on exceptions. The controller uses `send_file`, sets `Content-Disposition`, and registers cleanup through the response body close path; test cleanup explicitly.

- [ ] **Step 3: Implement selection UI**

The selection controller tracks row checkboxes and select-all-visible, disables **Download selected** when empty, posts `{ ids: [...] }` with the existing CSRF helper, reads the Blob, derives the filename from `Content-Disposition`, downloads through a temporary object URL, and revokes it. Search filtering does not silently select hidden rows.

- [ ] **Step 4: Run focused tests**

Run:

```bash
docker compose exec web bin/rails test test/services/control_center/ansible/playbook_archive_test.rb test/integration/api/v1/control_center/ansible/playbooks_test.rb
node --test web/test/javascript/ansible_playbook_selection_test.mjs
```

Expected: PASS.

### Task 9: Authoring regression checkpoint

- [ ] **Step 1: Check the concurrent boundary before shared-file verification**

Run: `git status --short` and inspect diffs for `routes.rb`, `base_controller.rb`, `icon_helper.rb`, importmap/controller index files, and `control_center.yaml`. Preserve contributor changes; resolve only genuinely overlapping hunks.

- [ ] **Step 2: Run the complete authoring and existing Control Center suites**

Run:

```bash
node --test web/test/javascript/*.mjs
docker compose exec web bin/rails test test/models/control_center test/services/control_center test/integration/control_center test/integration/api/v1/control_center
docker compose exec web bin/rails test
docker compose exec web bin/rubocop app/models/control_center/ansible app/services/control_center/ansible app/controllers/control_center/ansible app/controllers/api/v1/control_center/ansible test/models/control_center/ansible test/services/control_center/ansible test/integration/control_center/ansible test/integration/api/v1/control_center/ansible
git diff --check
```

Expected: all commands PASS and no whitespace errors.

- [ ] **Step 3: Perform manual browser smoke checks**

Verify create/edit/validate/delete for each authoring resource, encrypted/masked variable edits, single upload/download, drag overlay stability, conflict modal keyboard behavior, selected ZIP content, responsive layout, and dark mode. Confirm browser network responses never contain secret variable values.

- [ ] **Step 4: Optional user-authorized checkpoint commit**

Only if the user explicitly requests a commit:

```bash
git add web/app web/config/routes.rb web/config/openapi/control_center.yaml web/db/migrate/20260723020001_create_control_center_ansible_authoring.rb web/test
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Add Ansible authoring to the Control Center"
```
