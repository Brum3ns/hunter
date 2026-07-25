# Control Center Ansible Secure Execution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Execute one saved Ansible playbook safely against one saved inventory through an isolated pull-based executor, with immutable snapshots, strict host-key/CIDR checks, leases, redacted events, cancellation, health, and stale-work handling.

**Architecture:** A launch always creates a `RunGroup` and one child `Run`, leaving one lifecycle for later multi-playbook support. Rails resolves and encrypts a just-in-time payload, queues work in PostgreSQL, and exposes machine-only claim/write endpoints. A separately built Python container claims work, materializes secrets only in a mode-0700 tmpfs workspace, invokes pinned Ansible Runner, and reports redacted events. Rails independently redacts and caps all persisted output.

**Tech Stack:** Rails 8.1/PostgreSQL/Active Record Encryption, Python 3.13, ansible-core 2.21.2, ansible-runner 2.4.3, OpenSSH, Docker Compose, Minitest, Python `unittest`.

## Dependencies and constraints

- Complete the foundation and authoring plans first.
- This plan deliberately supports exactly one playbook per launch. The schema is group-ready; multi-playbook scheduling is the next plan.
- Never execute Ansible, SSH, DNS resolution, or `ssh-keyscan` in the Rails process.
- Machine endpoints authenticate `Runner` tokens with the `ansible` capability; they do not accept session cookies or `ApiToken` bearer tokens.
- Store only SHA-256 digests of machine bearer tokens and run leases.
- The claim response is the sole response allowed to contain decrypted run/utility payloads.
- Static validation is defense-in-depth, not the containment boundary. Keep the executor non-root, read-only, capability-free, and host-mount-free.
- Production must not start the executor with an empty `ANSIBLE_ALLOWED_CIDRS` value.
- Do not commit unless explicitly authorized by the user.

## New files

- `web/db/migrate/20260723030001_create_control_center_ansible_execution.rb`
- `web/app/models/control_center/ansible/run_group.rb`
- `web/app/models/control_center/ansible/run.rb`
- `web/app/models/control_center/ansible/run_event.rb`
- `web/app/models/control_center/ansible/executor_task.rb`
- `web/test/models/control_center/ansible/run_group_test.rb`
- `web/test/models/control_center/ansible/run_test.rb`
- `web/test/models/control_center/ansible/run_event_test.rb`
- `web/test/models/control_center/ansible/executor_task_test.rb`
- `web/app/services/control_center/ansible/run_payload.rb`
- `web/app/services/control_center/ansible/secret_redactor.rb`
- `web/app/services/control_center/ansible/single_launch.rb`
- `web/app/services/control_center/ansible/run_claim.rb`
- `web/app/services/control_center/ansible/executor_task_claim.rb`
- `web/app/services/control_center/ansible/lease_verifier.rb`
- `web/app/services/control_center/ansible/run_event_ingestor.rb`
- `web/app/services/control_center/ansible/run_result.rb`
- `web/app/services/control_center/ansible/executor_task_builder.rb`
- `web/app/services/control_center/ansible/executor_task_result.rb`
- `web/app/services/control_center/ansible/host_key_confirmation.rb`
- `web/app/services/control_center/ansible/run_cancellation.rb`
- `web/app/services/control_center/ansible/run_reaper.rb`
- `web/test/services/control_center/ansible/run_payload_test.rb`
- `web/test/services/control_center/ansible/secret_redactor_test.rb`
- `web/test/services/control_center/ansible/single_launch_test.rb`
- `web/test/services/control_center/ansible/run_claim_test.rb`
- `web/test/services/control_center/ansible/executor_task_claim_test.rb`
- `web/test/services/control_center/ansible/lease_verifier_test.rb`
- `web/test/services/control_center/ansible/run_event_ingestor_test.rb`
- `web/test/services/control_center/ansible/run_result_test.rb`
- `web/test/services/control_center/ansible/executor_task_builder_test.rb`
- `web/test/services/control_center/ansible/executor_task_result_test.rb`
- `web/test/services/control_center/ansible/host_key_confirmation_test.rb`
- `web/test/services/control_center/ansible/run_cancellation_test.rb`
- `web/test/services/control_center/ansible/run_reaper_test.rb`
- `web/app/controllers/api/v1/control_center/ansible/run_groups_controller.rb`
- `web/app/controllers/api/v1/control_center/ansible/runs_controller.rb`
- `web/app/controllers/api/v1/control_center/ansible/run_events_controller.rb`
- `web/app/controllers/api/v1/control_center/ansible/executor_health_controller.rb`
- `web/app/controllers/api/v1/ansible_executor/base_controller.rb`
- `web/app/controllers/api/v1/ansible_executor/tasks_controller.rb`
- `web/app/controllers/api/v1/ansible_executor/runs_controller.rb`
- `web/app/controllers/api/v1/ansible_executor/run_events_controller.rb`
- human/machine API integration tests under `web/test/integration/api/v1/control_center/ansible/` and `web/test/integration/api/v1/ansible_executor/`
- `web/app/views/control_center/ansible/runs/show.html.erb`
- `web/app/javascript/controllers/ansible_runs_controller.js`
- `web/test/integration/control_center/ansible/runs_test.rb`
- `web/test/javascript/ansible_runs_test.mjs`
- `ansible_executor/requirements.txt`
- `ansible_executor/Dockerfile`
- `ansible_executor/entrypoint.sh`
- `ansible_executor/hunter_ansible/__init__.py`
- `ansible_executor/hunter_ansible/config.py`
- `ansible_executor/hunter_ansible/client.py`
- `ansible_executor/hunter_ansible/workspace.py`
- `ansible_executor/hunter_ansible/target_policy.py`
- `ansible_executor/hunter_ansible/worker.py`
- `ansible_executor/hunter_ansible/main.py`
- Python unit tests under `ansible_executor/tests/`
- `web/lib/tasks/control_center_ansible.rake`

## Modified files

- `web/config/routes.rb`
- `web/config/recurring.yml`
- `web/config/openapi/control_center.yaml`
- `docker-compose.yaml`
- `docker-compose.prod.yaml`
- `.env.example`
- `web/app/models/control_center/ansible/inventory.rb`

---

### Task 1: Add execution persistence and state invariants

**Files:** migration, four models, model tests.

**State constants:**

```ruby
RunGroup::STATUSES = %w[queued running succeeded failed partially_succeeded canceling canceled].freeze
Run::STATUSES = %w[waiting queued validating running succeeded failed canceling canceled skipped].freeze
ExecutorTask::KINDS = %w[syntax_check host_key_scan connectivity_test].freeze
ExecutorTask::STATUSES = %w[queued running succeeded failed canceled].freeze
```

- [ ] **Step 1: Write failing model tests**

Test status/mode/failure-policy inclusion, group ordered children, event UUID uniqueness within one run, counter uniqueness within one run, encrypted group/task payload ciphertext, terminal predicates, and the rule that only queued work is claimable.

- [ ] **Step 2: Add the exact schema**

```ruby
class CreateControlCenterAnsibleExecution < ActiveRecord::Migration[8.1]
  def change
    create_table :control_center_ansible_run_groups do |t|
      t.string :status, null: false, default: "queued"
      t.string :execution_mode, null: false, default: "sequential"
      t.string :failure_policy, null: false, default: "stop"
      t.integer :concurrency_limit, null: false, default: 1
      t.references :inventory, foreign_key: { to_table: :control_center_ansible_inventories, on_delete: :nullify }
      t.references :credential, foreign_key: { to_table: :control_center_ansible_credentials, on_delete: :nullify }
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.text :execution_payload
      t.jsonb :launch_snapshot, null: false, default: {}
      t.datetime :cancel_requested_at
      t.datetime :started_at
      t.datetime :completed_at
      t.timestamps
    end
    add_index :control_center_ansible_run_groups, %i[status created_at],
      name: "idx_ansible_run_groups_status_created"

    create_table :control_center_ansible_runs do |t|
      t.references :run_group, null: false,
        foreign_key: { to_table: :control_center_ansible_run_groups }
      t.references :playbook, foreign_key: { to_table: :control_center_ansible_playbooks, on_delete: :nullify }
      t.integer :position, null: false
      t.string :status, null: false, default: "queued"
      t.text :playbook_yaml, null: false
      t.text :inventory_yaml, null: false
      t.text :known_hosts, null: false
      t.jsonb :variable_audit, null: false, default: {}
      t.jsonb :secret_variable_names, null: false, default: []
      t.string :playbook_name, null: false
      t.string :inventory_name, null: false
      t.string :credential_name, null: false
      t.string :credential_fingerprint
      t.string :host_limit
      t.boolean :check_mode, null: false, default: false
      t.integer :timeout_seconds, null: false
      t.string :error_code
      t.text :error_detail
      t.integer :exit_status
      t.integer :ok_count, null: false, default: 0
      t.integer :changed_count, null: false, default: 0
      t.integer :failed_count, null: false, default: 0
      t.integer :unreachable_count, null: false, default: 0
      t.bigint :stored_event_bytes, null: false, default: 0
      t.boolean :truncated, null: false, default: false
      t.references :runner, foreign_key: { on_delete: :nullify }
      t.string :lease_digest
      t.datetime :lease_expires_at
      t.datetime :heartbeat_at
      t.datetime :queued_at
      t.datetime :claim_deadline
      t.datetime :started_at
      t.datetime :completed_at
      t.datetime :cancel_requested_at
      t.timestamps
    end
    add_index :control_center_ansible_runs, %i[status queued_at id],
      name: "idx_ansible_runs_claim_order"
    add_index :control_center_ansible_runs, %i[run_group_id position], unique: true,
      name: "idx_ansible_runs_group_position"

    create_table :control_center_ansible_run_events do |t|
      t.references :run, null: false, foreign_key: { to_table: :control_center_ansible_runs }
      t.references :runner, foreign_key: { on_delete: :nullify }
      t.string :event_uuid, null: false
      t.string :parent_uuid
      t.bigint :counter, null: false
      t.string :event_type, null: false
      t.string :play
      t.string :task
      t.string :host
      t.datetime :event_time
      t.text :stdout
      t.jsonb :event_data, null: false, default: {}
      t.boolean :truncated, null: false, default: false
      t.timestamps
    end
    add_index :control_center_ansible_run_events, %i[run_id event_uuid], unique: true,
      name: "idx_ansible_run_events_uuid"
    add_index :control_center_ansible_run_events, %i[run_id counter], unique: true,
      name: "idx_ansible_run_events_counter"

    create_table :control_center_ansible_executor_tasks do |t|
      t.string :kind, null: false
      t.string :status, null: false, default: "queued"
      t.references :inventory, foreign_key: { to_table: :control_center_ansible_inventories, on_delete: :nullify }
      t.references :playbook, foreign_key: { to_table: :control_center_ansible_playbooks, on_delete: :nullify }
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.text :execution_payload
      t.jsonb :result, null: false, default: {}
      t.string :error_code
      t.text :error_detail
      t.references :runner, foreign_key: { on_delete: :nullify }
      t.string :lease_digest
      t.datetime :lease_expires_at
      t.datetime :heartbeat_at
      t.datetime :claim_deadline, null: false
      t.datetime :started_at
      t.datetime :completed_at
      t.timestamps
    end
    add_index :control_center_ansible_executor_tasks, %i[status created_at],
      name: "idx_ansible_executor_tasks_claim_order"
  end
end
```

- [ ] **Step 3: Implement model boundaries**

Use namespaced table names and associations, declare `serialize :execution_payload, coder: JSON` before non-deterministic `encrypts :execution_payload` on group/task, and add scopes `queued.oldest_first`. A raw SQL read must contain ciphertext rather than any JSON secret. Define `terminal?` from explicit terminal arrays. Validate `timeout_seconds` in `60..86_400`, concurrency in `1..20` at the model boundary, and immutable snapshot columns after persistence. `RunEvent` belongs to an optional runner so revocation does not destroy audit history. Do not add callbacks that schedule or claim work.

- [ ] **Step 4: Migrate and run tests**

Run: `docker compose exec web bin/rails db:migrate && docker compose exec web bin/rails test test/models/control_center/ansible`

Expected: PASS.

### Task 2: Build immutable payloads, redaction, and single-playbook launch

**Files:** `run_payload.rb`, `secret_redactor.rb`, `single_launch.rb`, service tests.

**Launch interface:**

```ruby
SingleLaunch.call(
  user: Current.user,
  playbook_id:,
  inventory_id:,
  credential_id: nil,
  variable_set_ids: [],
  overrides: [],
  host_limit: nil,
  check_mode: false,
  timeout_seconds: 3600
) # => persisted RunGroup with one queued child
```

- [ ] **Step 1: Write failure-first launch tests**

Cover missing/deleted credential, absent required auth secret, unapproved/empty known hosts, invalid variable resolution, invalid host limit, timeout bounds, invalid saved YAML, and transaction rollback. Cover successful snapshots and prove that edits/credential rotation after launch do not alter decrypted group payload or child audit columns. Assert plaintext credential/secret values occur only inside the encrypted `execution_payload`, never in snapshot JSON or run columns.

- [ ] **Step 2: Implement exact-value recursive redaction**

`SecretRedactor.call(value, secrets:)` accepts String/Array/Hash/primitive. Remove empty secrets, sort longest first, and replace every exact substring with `[FILTERED]`; redact hash values recursively and replace a key only when it exactly equals a secret. Cap one serialized event at 64 KiB by keeping the first 75% and final 25% with `\n...[TRUNCATED]...\n`. It returns `Result(value:, truncated:, bytes:)` and never mutates input.

- [ ] **Step 3: Implement transactional launch**

Validate saved YAML again, select the override credential or inventory default, resolve variables using the authoring service, and create:

```ruby
payload = {
  schema_version: 1,
  playbook_yaml: playbook.yaml_content,
  inventory_yaml: inventory.yaml_content,
  known_hosts: inventory.known_hosts,
  variables: resolved.values,
  secrets: {
      username: credential.username,
    private_key: credential.private_key,
    ssh_password: credential.ssh_password,
    private_key_passphrase: credential.private_key_passphrase,
    become_password: credential.become_password
  },
  options: { host_limit:, check_mode:, timeout_seconds: }
}
```

The group `launch_snapshot` contains resource IDs/names/checksums, selected variable-set IDs, non-secret overrides, secret override names, and credential name/fingerprint only. Create one child at position 0/status queued with `queued_at: Time.current` and `claim_deadline` from `ANSIBLE_CLAIM_TIMEOUT_SECONDS` (default 300). Never log or inspect the payload.

- [ ] **Step 4: Verify focused services**

Run: `docker compose exec web bin/rails test test/services/control_center/ansible/secret_redactor_test.rb test/services/control_center/ansible/run_payload_test.rb test/services/control_center/ansible/single_launch_test.rb`

Expected: PASS.

### Task 3: Add the human run API and history views

**Files:** run-group/run/event API controllers and tests; routes/OpenAPI; web controllers/views; polling controller/tests.

**Human API routes:**

```ruby
resources :run_groups, only: %i[index show create] do
  post :cancel, on: :member
end
resources :runs, only: :show do
  post :cancel, on: :member
  resources :events, only: :index, controller: "run_events"
end
resource :executor_health, only: :show, controller: "executor_health"
```

- [ ] **Step 1: Write API tests**

Test scoped auth/CSRF, launch validation, newest-first pagination, group detail with child summaries, run detail without execution payload/lease digest/secrets, event counter pagination, idempotent cancellation requests, terminal cancel conflict, and executor health metadata. Use literal assertions that serialized JSON does not include keys matching `/password|private_key|execution_payload|lease_digest/`.

- [ ] **Step 2: Implement serializers and actions**

Create with `SingleLaunch`; render `201` and group detail. Cancel sets `cancel_requested_at` once, immediately cancels queued/waiting children, changes active children to `canceling`, and lets the result/reaper finish the group. Health reports configured/running/last-seen counts for `ansible` runners and the oldest queued age, never runner token data.

- [ ] **Step 3: Build Runs index/detail and polling**

Replace the authoring-plan Runs empty state with group history. Detail shows aggregate status, immutable selections, one child, counts/duration, ordered event rows, redacted stdout, truncation indicator, cancel button, and executor-unavailable guidance. Poll JSON every two seconds while non-terminal; stop when terminal, on page disconnect, and after repeated network errors with a visible retry control.

- [ ] **Step 4: Verify human surfaces**

Run:

```bash
docker compose exec web bin/rails test test/integration/api/v1/control_center/ansible/run_groups_test.rb test/integration/api/v1/control_center/ansible/runs_test.rb test/integration/control_center/ansible/runs_test.rb
docker compose exec web bin/rails test test/integration/api/v1/openapi_test.rb
```

Expected: PASS.

### Task 4: Implement atomic claims, leases, event ingestion, and terminal results

**Files:** claim/lease/ingestion/result/reaper services and tests; machine controllers/routes/tests.

**Machine routes:**

```ruby
namespace :ansible_executor do
  post "tasks/claim", to: "tasks#claim"
  post "tasks/:id/heartbeat", to: "tasks#heartbeat"
  post "tasks/:id/result", to: "tasks#result"
  post "runs/claim", to: "runs#claim"
  post "runs/:id/start", to: "runs#start"
  post "runs/:id/heartbeat", to: "runs#heartbeat"
  get  "runs/:id/control", to: "runs#control"
  post "runs/:id/events", to: "run_events#create"
  post "runs/:id/result", to: "runs#result"
end
```

- [ ] **Step 1: Write concurrency and protocol tests first**

Cover runner authentication, ansible-capability enforcement, two concurrent claims returning different work, oldest eligible order, lease digest persistence, claim payload returned once, wrong/stale lease rejection, validating-to-running start, heartbeat extension, cancellation polling, duplicate event UUID/counter idempotency, batch/body caps, terminal result idempotency, conflicting second result, event redaction, 20 MiB run cap, and no plaintext in responses/errors/log captures.

- [ ] **Step 2: Implement machine authentication separately from `Api::BaseController`**

Create `Api::V1::AnsibleExecutor::BaseController < ActionController::API`. Parse exactly one `Authorization: Bearer` token, authenticate through the existing digest-only `Runner` lookup (deletion is revocation; Runner has no separate active flag), require `runner.kinds.include?("ansible")`, assign `Current.runner`, and return stable `401 unauthorized` or `403 insufficient_capability`. Apply request body limits before JSON parsing where practical.

- [ ] **Step 3: Implement row-locked claim and leases**

Within a transaction, select the oldest eligible row with `lock("FOR UPDATE SKIP LOCKED")`. Generate `lease = SecureRandom.urlsafe_base64(32)`, return that exact string, persist `Digest::SHA256.hexdigest(lease)`, runner, timestamps, and `lease_expires_at` from `ANSIBLE_LEASE_SECONDS` (default 45). Set child `validating` and group `running` before decrypting/returning payload. Verify later requests by digesting the submitted lease, using constant-time comparison, and locking the row for state changes. The start action accepts only an owned, unexpired `validating` run after syntax success and changes it to `running` idempotently.

- [ ] **Step 4: Implement bounded idempotent ingestion**

Accept at most 100 events and 1 MiB JSON per request. Validate required UUID/counter/type fields. Redact recursively using secret values from the still-encrypted group payload, then apply per-event and run caps. Insert with unique constraints and treat an identical duplicate as success; reject the same identity with different content. Once the run cap is reached, retain status/summary events without verbose stdout and mark run/events truncated.

- [ ] **Step 5: Implement terminal results and purge**

Validate result status (`succeeded`, `failed`, `canceled`), counts, exit status, stable error code, and safe detail. The first valid terminal result wins under a row lock. Clear lease fields, set completion time, update the one-child group status, set credential `last_used_at`, and purge group `execution_payload` in the same transaction. Return the prior result for an identical retry.

- [ ] **Step 6: Implement stale-work reaping**

`RunReaper.call(now: Time.current)` locks batches and:

- fails queued runs past their per-child claim deadline as `executor_unavailable` and then aggregates/schedules their groups;
- fails validating/running/canceling runs past lease expiry as `executor_lost`;
- never requeues a run;
- clears expired leases and encrypted execution payloads;
- marks expired executor tasks failed and clears their payloads.

Wire a once-per-minute Solid Queue recurring task in `web/config/recurring.yml` and a manual `control_center:ansible:reap` rake task.

- [ ] **Step 7: Run machine protocol tests**

Run: `docker compose exec web bin/rails test test/services/control_center/ansible test/integration/api/v1/ansible_executor`

Expected: PASS.

### Task 5: Add host-key scan, confirmation, connectivity, and isolated syntax tasks

**Files:** utility task builder/result services; inventory API controller/tests; executor-task machine tests.

**Human routes added to inventories:**

```ruby
post :syntax_check, on: :member
post :host_key_scan, on: :member
post :confirm_host_keys, on: :member
post :connectivity_test, on: :member
get  "executor_tasks/:task_id", action: :executor_task, on: :member
```

- [ ] **Step 1: Write utility lifecycle tests**

Assert scan queues only host aliases/addresses/ports and no credential, candidate results are explicitly `trusted: false`, confirmation requires exact candidate material plus an independently entered expected SHA256 fingerprint for every host, mismatch stores nothing, connectivity tasks contain an encrypted credential payload, syntax tasks snapshot YAML, completed/expired tasks purge payload, and utility claim fairness allows at most five consecutive tasks before checking a run.

- [ ] **Step 2: Implement task builders and result validation**

Inventory parsing produces normalized target descriptors. `host_key_scan` queues descriptors only. `syntax_check` queues playbook/inventory snapshots and generated non-secret execution metadata. `connectivity_test` queues descriptors, approved known hosts, and credential secret material. Result ingestion allowlists fields per task kind; it never persists command output containing credentials.

- [ ] **Step 3: Implement explicit host-key confirmation**

Require `{ candidates: [{ host:, port:, known_hosts_line:, scanned_fingerprint:, expected_fingerprint: }] }`. Normalize `SHA256:` fingerprints and require scanned/expected equality using constant-time comparison. Validate the known-host line corresponds to host/port and its decoded key fingerprints to the provided value. Replace only entries explicitly confirmed in one transaction; never trust on first use or auto-replace a mismatch.

- [ ] **Step 4: Add inventory UI controls and polling**

Display scan candidates in an untrusted callout, require the admin to type/paste each expected out-of-band fingerprint, and show stored fingerprints separately. Disable Run/connectivity when known hosts or credentials are incomplete. Poll the utility-task endpoint until terminal.

- [ ] **Step 5: Verify utility flows**

Run: `docker compose exec web bin/rails test test/services/control_center/ansible/executor_task* test/integration/api/v1/control_center/ansible/inventories_test.rb test/integration/api/v1/ansible_executor/tasks_test.rb`

Expected: PASS.

### Task 6: Build the isolated Python executor

**Files:** all under `ansible_executor/`.

**Pinned dependencies:**

```text
ansible-core==2.21.2
ansible-runner==2.4.3
```

Use Python 3.13 and only the standard library for Hunter HTTP, CIDR, filesystem, process, signal, and test support.

- [ ] **Step 1: Write Python tests before implementation**

Create `unittest` suites for configuration fail-closed behavior, bearer normalization, claim polling, workspace mode/cleanup on all exits, no secret logging, DNS resolution and every-address CIDR enforcement, fixed SSH port 22 for production inventory targets, known-host matching, payload materialization, syntax failure before execution, event batching/retry, heartbeat, stale lease handling, cancellation process-group TERM/KILL, timeout, result idempotency, and bounded tmpfs buffering.

Run: `python3 -m unittest discover -s ansible_executor/tests -v`

Expected: FAIL until modules exist.

- [ ] **Step 2: Implement strict configuration**

`Config.from_env()` requires `HUNTER_URL`, `HUNTER_RUNNER_TOKEN`, and at least one parsed `ANSIBLE_ALLOWED_CIDRS`; rejects URL credentials/query/fragment; requires HTTPS except hostnames `web`, `localhost`, or loopback development; defaults poll 2s, heartbeat 15s, lease awareness 45s, max event batch 100, buffer 5 MiB, cancel grace 10s, and workspace `/runner`.

- [ ] **Step 3: Implement workspace materialization**

Create one `tempfile.mkdtemp(dir="/runner")`, chmod 0700, and write project/inventory/private-data files with 0600. Generate inventory that pins each approved resolved IP as `ansible_host`, sets credential username/auth through Ansible Runner env/password interfaces, writes approved `known_hosts`, sets strict host checking, disables host-key updates, and never places a secret in argv or logs. Cleanup in `finally` and SIGTERM handling.

- [ ] **Step 4: Enforce targets before SSH**

Resolve every target with `socket.getaddrinfo`, reject empty results, reject if any usable address is outside the allowed networks, and pin one approved address. Reject loopback, link-local, multicast, unspecified, and metadata addresses unless an allowed CIDR explicitly contains them and a test-only development flag is set. Allow inventory port values only when configured by an explicit `ANSIBLE_ALLOWED_PORTS` list, default `22`.

- [ ] **Step 5: Run syntax and Ansible Runner with fixed options**

Execute authoritative `ansible-playbook --syntax-check` with a fixed executable and argument list, sanitized environment, inventory path, playbook path, and optional typed host limit/check flag. Then use `ansible_runner.run` with the fixed private-data directory, timeout, forks limit, event handler, cancel callback, and finished callback. Start subprocesses in a new process group; cancellation sends TERM and then KILL after grace.

- [ ] **Step 6: Implement API loop and event handling**

Prefer utility claims with the five-task fairness cap, then run claims. Heartbeat concurrently while processing. Redact known secrets before buffering; Rails remains the second redaction boundary. Retry transient HTTP failures with exponential backoff bounded by the lease window, buffer only under the configured bytes in tmpfs, stop on `401`, `403`, or lease conflict, and post a terminal result once.

- [ ] **Step 7: Verify executor tests**

Run:

```bash
python3 -m unittest discover -s ansible_executor/tests -v
docker build -f ansible_executor/Dockerfile -t hunter-ansible-executor:test .
docker run --rm hunter-ansible-executor:test ansible-playbook --version
```

Expected: tests PASS and version output reports ansible-core 2.21.2.

### Task 7: Add hardened Compose services and deployment configuration

**Files:** executor Dockerfile/entrypoint, compose files, `.env.example`.

- [ ] **Step 1: Build a non-root image**

Use `python:3.13-slim`, install only `openssh-client` and required runtime libraries, install the hashed/pinned requirements, create an unprivileged `ansible` UID/GID, copy application read-only, set `PYTHONDONTWRITEBYTECODE=1`, and use an exec-form entrypoint. No shell, Docker socket, or Hunter source mount is needed at runtime.

- [ ] **Step 2: Add development and production services**

Both compose services must include:

```yaml
    read_only: true
    cap_drop: [ALL]
    security_opt:
      - no-new-privileges:true
    tmpfs:
      - /runner:rw,noexec,nosuid,nodev,mode=0700,size=64m
    pids_limit: 256
    init: true
    restart: unless-stopped
```

Pass only Hunter URL/token, allowed CIDRs/ports, limits, and pinned operational settings. Publish no ports and mount no host directory. Production uses deployment-provided `HUNTER_ANSIBLE_RUNNER_TOKEN` and `ANSIBLE_ALLOWED_CIDRS` without defaults. Development may leave the service behind an explicit `ansible` profile until a token exists.

- [ ] **Step 3: Validate configurations**

Run:

```bash
docker compose config --quiet
docker compose -f docker-compose.prod.yaml config --quiet
docker compose --profile ansible build ansible-executor
```

Expected: all commands succeed; manually inspect resolved config to confirm no secret default and no host mounts/ports.

### Task 8: Execution security and regression checkpoint

- [ ] **Step 1: Run focused and full test suites**

```bash
python3 -m unittest discover -s ansible_executor/tests -v
docker compose exec web bin/rails test test/models/control_center/ansible test/services/control_center/ansible test/integration/control_center/ansible test/integration/api/v1/control_center/ansible test/integration/api/v1/ansible_executor
docker compose exec web bin/rails test
docker compose exec web bin/brakeman --no-pager
docker compose exec web bin/rubocop app/models/control_center/ansible app/services/control_center/ansible app/controllers/control_center/ansible app/controllers/api/v1/control_center/ansible app/controllers/api/v1/ansible_executor
git diff --check
```

Expected: PASS; Brakeman reports no new warning.

- [ ] **Step 2: Inspect secret and execution boundaries manually**

Search response serializers, logs, exceptions, fixtures, Compose defaults, and generated artifacts for known test secrets. Confirm no Rails code invokes `ansible`, `ssh`, `ssh-keyscan`, or a shell; no executor command uses `shell=True`; claim is the only decrypted-payload response; terminal/stale work clears payload; strict host checking and allowed-CIDR checks fail closed.

- [ ] **Step 3: Optional user-authorized checkpoint commit**

Only if the user explicitly requests a commit:

```bash
git add ansible_executor web/app web/config web/db/migrate/20260723030001_create_control_center_ansible_execution.rb web/lib/tasks/control_center_ansible.rake web/test .env.example docker-compose.yaml docker-compose.prod.yaml
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Add isolated Ansible execution and run history"
```
