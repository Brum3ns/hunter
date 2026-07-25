# Control Center Ansible Orchestration and Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the proven single-run path to ordered multi-playbook groups with sequential stop/continue and bounded parallel execution, then complete cancellation, retry-as-new, security regression, and an optional disposable end-to-end smoke profile.

**Architecture:** Every launch continues to use `RunGroup` plus ordered child `Run` records. A transactionally locked scheduler is the only component allowed to promote waiting children. The existing executor still claims individual queued children and does not need orchestration logic. Parallelism is capped independently from Ansible forks. Retry creates new audit identities and resolves current secrets rather than replaying secret material from history.

**Tech Stack:** Existing Rails and Python executor stack from the first three plans, PostgreSQL row locking, Stimulus, Docker Compose, Minitest, Python `unittest`.

## Dependencies and constraints

- Complete the foundation, authoring, and secure-execution plans first.
- Sequential is the default; order is explicit and persisted.
- Sequential defaults to `stop`; `continue` is an explicit launch choice.
- Parallel is explicit, displays a warning, ignores the sequential failure-policy control, and is capped by `ANSIBLE_MAX_PARALLEL_PLAYBOOKS` (default 3).
- `ANSIBLE_MAX_PARALLEL_PLAYBOOKS` limits simultaneous playbooks in one group. `ANSIBLE_FORKS` separately limits hosts inside one playbook.
- No automatic retry after executor loss, timeout, authentication failure, or partial execution.
- Retry always creates a new group and child IDs.
- Preserve concurrent Whiterabbit changes and do not commit without explicit permission.

---

### Task 1: Specify and implement the group scheduler

**Files:**

- Create `web/app/services/control_center/ansible/group_scheduler.rb`
- Create `web/test/services/control_center/ansible/group_scheduler_test.rb`
- Modify result, reaper, and cancellation services from the execution plan

**Interface:**

```ruby
ControlCenter::Ansible::GroupScheduler.call(group_id:, now: Time.current)
# Locks the group and eligible children, promotes/cancels/skips children,
# aggregates status, purges terminal payload, and returns the reloaded group.
```

- [ ] **Step 1: Write the complete state-transition matrix before code**

Create tests for:

- one-child queued/running/succeeded/failed/canceled groups;
- sequential launch queues position 0 and leaves all others waiting;
- sequential success promotes exactly the next position;
- sequential failure with `stop` marks every waiting child skipped;
- sequential failure with `continue` promotes exactly the next child;
- a canceled active child cancels remaining waiting children when group cancellation was requested;
- parallel launch promotes only `min(requested_limit, system_limit, waiting_count)`;
- each parallel completion promotes enough children to refill, never exceed, the cap;
- parallel failures do not stop promotion;
- two scheduler calls racing cannot over-promote;
- group status definitions: all success → succeeded; failures and no successes → failed; mixed success/failure/skip → partially_succeeded; requested cancellation after any earlier result → canceled when all active children stop;
- terminal groups clear `execution_payload` exactly once;
- calling the scheduler repeatedly is idempotent.

- [ ] **Step 2: Confirm failure**

Run: `docker compose exec web bin/rails test test/services/control_center/ansible/group_scheduler_test.rb`

Expected: FAIL because the scheduler is absent.

- [ ] **Step 3: Implement one locked scheduling boundary**

Start one transaction, lock the group by ID, and lock `group.runs.order(:position)`. Read the system cap using:

```ruby
system_cap = Integer(ENV.fetch("ANSIBLE_MAX_PARALLEL_PLAYBOOKS", "3"), 10)
system_cap = system_cap.clamp(1, 20)
effective_cap = [group.concurrency_limit, system_cap].min
```

For sequential groups, count active states `%w[queued validating running canceling]`; promote only when none are active. With `stop`, a failed/canceled child (without a group cancellation) skips later waiting children. With `continue`, promote the lowest-position waiting child. For parallel groups, promote the lowest waiting positions until active count reaches `effective_cap`. Every promotion atomically sets `status: "queued"`, `queued_at: now`, and a fresh per-child `claim_deadline` from `ANSIBLE_CLAIM_TIMEOUT_SECONDS`; waiting time never consumes a later child's claim window.

Aggregate only after promotion/cancellation decisions. Set `completed_at` and clear payload only when every child is terminal. Never decrypt payload while deciding scheduling state.

- [ ] **Step 4: Invoke scheduling at all state boundaries**

Call after group creation, accepted terminal result, group/child cancellation, and stale-work reaping. Do not use model callbacks. Add `control_center:ansible:schedule` to the once-per-minute maintenance task as recovery for an interrupted post-result call.

- [ ] **Step 5: Verify**

Run: `docker compose exec web bin/rails test test/services/control_center/ansible/group_scheduler_test.rb test/services/control_center/ansible/run_result_test.rb test/services/control_center/ansible/run_reaper_test.rb`

Expected: PASS.

### Task 2: Replace single launch with ordered multi-launch

**Files:**

- Create `web/app/services/control_center/ansible/group_launch.rb`
- Create `web/test/services/control_center/ansible/group_launch_test.rb`
- Modify run-group API controller/tests and OpenAPI
- Keep `single_launch.rb` temporarily as a delegating compatibility wrapper, then remove it after all callers migrate

**Interface:**

```ruby
GroupLaunch.call(
  user: Current.user,
  playbook_ids: [12, 4, 9],
  inventory_id: 3,
  credential_id: nil,
  variable_set_ids: [8],
  overrides: [{ name: "release", value_type: "string", value: "2026.07", secret: false }],
  execution_mode: "sequential",
  failure_policy: "stop",
  concurrency_limit: 1,
  host_limit: nil,
  check_mode: false,
  timeout_seconds: 3600
)
```

- [ ] **Step 1: Write ordered-launch and validation tests**

Assert one to 50 unique playbook IDs are required; request order becomes child `position`; duplicate IDs are rejected instead of silently deduplicated; missing IDs fail the whole transaction; sequential requires concurrency 1 and accepts stop/continue; parallel forces failure policy `continue`, requires explicit acknowledgement, and accepts only `1..system_cap`; all children snapshot exact saved YAML and resource names; variables are resolved separately for each playbook so its attached sets apply; one failure rolls back the entire group.

- [ ] **Step 2: Version the encrypted payload without breaking outstanding v1 work**

New groups store:

```ruby
{
  schema_version: 2,
  shared: {
    inventory_yaml: inventory.yaml_content,
    known_hosts: inventory.known_hosts,
    credential: {
      username: credential.username,
      private_key: credential.private_key,
      ssh_password: credential.ssh_password,
      private_key_passphrase: credential.private_key_passphrase,
      become_password: credential.become_password
    },
    options: { host_limit:, check_mode:, timeout_seconds: }
  },
  children: playbooks.each_with_index.to_h do |playbook, position|
    [position.to_s, { variables: resolved_for(playbook).values }]
  end
}
```

Keep claim decoding for schema version 1 until no queued/running v1 group remains. Unknown schema versions fail safely as `payload_version_unsupported` without exposing payload data.

- [ ] **Step 3: Persist ordered children and schedule once**

Create every child as `waiting`, set immutable snapshots/audit metadata, commit the group, then call `GroupScheduler`. The scheduler queues the first sequential child or the initial parallel window. `launch_snapshot` records ordered playbook IDs/names/checksums, choices, non-secret overrides, secret override names, and the effective cap; it contains no values marked secret.

- [ ] **Step 4: Change the API request contract**

`POST /api/v1/control_center/ansible/run_groups` accepts:

```json
{
  "playbook_ids": [12, 4, 9],
  "inventory_id": 3,
  "credential_id": 2,
  "variable_set_ids": [8],
  "overrides": [],
  "execution_mode": "sequential",
  "failure_policy": "stop",
  "concurrency_limit": 1,
  "parallel_risk_acknowledged": false,
  "host_limit": null,
  "check_mode": false,
  "timeout_seconds": 3600
}
```

Reject unexpected option fields and type coercions that would turn arbitrary strings into truthy booleans. Return effective concurrency and ordered children in the `201` response.

- [ ] **Step 5: Verify service and API tests**

Run: `docker compose exec web bin/rails test test/services/control_center/ansible/group_launch_test.rb test/integration/api/v1/control_center/ansible/run_groups_test.rb test/integration/api/v1/openapi_test.rb`

Expected: PASS.

### Task 3: Build the multi-playbook launch experience

**Files:**

- Create `web/app/javascript/controllers/ansible_launch_controller.js`
- Create `web/app/javascript/lib/ansible_launch_state.js`
- Create `web/test/javascript/ansible_launch_state_test.mjs`
- Modify playbook and run views/integration tests

**Pure state interface:**

```javascript
createLaunchState({ playbooks, selectedIds, mode, failurePolicy, concurrency, systemCap })
movePlaybook(state, id, delta)
validateLaunch(state)
serializeLaunch(state)
```

- [ ] **Step 1: Test UI state independently**

Cover one/multiple selection, explicit ordering, keyboard move controls, sequential defaults, stop/continue, switching to parallel, risk acknowledgement reset, concurrency clamping, failure-policy disabling in parallel, separate forks explanation, missing inventory/credential/host keys, typed overrides, and exact request serialization.

- [ ] **Step 2: Build the accessible launch dialog**

From Playbooks, **Run** opens a modal with checked ordered playbooks, Up/Down controls, shared inventory, optional credential override, launch variable sets, typed temporary overrides, host limit, check mode, timeout, and mode. Sequential is preselected with stop. Parallel reveals a warning about shared-host package locks/services/files/reboots and requires a checkbox acknowledgement before submit. Display the deployment cap.

- [ ] **Step 3: Add progress-oriented group detail**

Show `completed/total`, aggregate status, execution mode/failure policy/effective cap, and ordered child cards. Each child independently shows waiting/queued/validating/running/terminal state, counts, timing, events link, cancellation, and retry. Polling updates the group and currently visible child events without losing focus or scroll position.

- [ ] **Step 4: Verify JS and Rails views**

Run:

```bash
node --test web/test/javascript/ansible_launch_state_test.mjs
docker compose exec web bin/rails test test/integration/control_center/ansible/runs_test.rb test/integration/control_center/ansible/playbooks_test.rb
```

Expected: PASS.

### Task 4: Complete group/child cancellation semantics

**Files:** cancellation service/controllers/tests; executor cancellation tests.

- [ ] **Step 1: Write cancellation race tests**

Cover group cancellation before any claim, during one sequential run, during several parallel runs, concurrent terminal result vs cancellation, repeated cancel, child-only cancellation, executor observing `cancel_requested`, TERM success, KILL fallback, and lease loss during cancellation. Assert group cancellation always ends `canceled` once active children are terminal, even if earlier children succeeded.

- [ ] **Step 2: Implement transactional requests**

Under group/child locks, set request timestamps once. Group cancellation immediately sets waiting/queued children canceled and active children canceling. Child cancellation affects only that child unless sequential stop policy then causes the scheduler to skip later children. Never delete events, snapshots, or historical group rows.

- [ ] **Step 3: Keep executor behavior best-effort and explicit**

The control endpoint returns only `{ cancel_requested: true|false, lease_expires_at: ... }`. The executor stops the full process group, reports terminal canceled if it still owns the lease, cleans workspace in `finally`, and never claims another child before cleanup. The UI states that already-applied remote changes cannot be rolled back.

- [ ] **Step 4: Verify**

Run:

```bash
docker compose exec web bin/rails test test/services/control_center/ansible/cancellation_test.rb test/integration/api/v1/control_center/ansible/run_groups_test.rb test/integration/api/v1/control_center/ansible/runs_test.rb
python3 -m unittest ansible_executor.tests.test_cancellation -v
```

Expected: PASS.

### Task 5: Add retry-as-new without replaying secrets

**Files:** retry service/API/web controls/tests/OpenAPI.

**Route:**

```ruby
post :retry, on: :member # for both run_groups and runs
```

- [ ] **Step 1: Write security-focused retry tests**

Assert retry is rejected for non-terminal work; creates new group/run IDs; never reuses/decrypts a purged historical payload; reloads current playbooks/inventory/credential/variable sets by saved references; asks for replacements when a referenced resource was deleted; uses the current credential secret after rotation; pre-fills only non-secret selections/options; and defaults a failed child retry to one selected playbook.

- [ ] **Step 2: Implement preflight then normal launch**

`RetryPreparation.call(record)` returns either a launch form descriptor or stable missing-reference errors. The browser shows the ordinary launch dialog prefilled from that descriptor. Submission calls the same `GroupLaunch` endpoint; do not create a server endpoint that blindly clones execution data. The `retry` actions therefore return only the descriptor and may never return prior secret values.

- [ ] **Step 3: Verify**

Run: `docker compose exec web bin/rails test test/services/control_center/ansible/retry_preparation_test.rb test/integration/api/v1/control_center/ansible/run_groups_test.rb test/integration/api/v1/control_center/ansible/runs_test.rb`

Expected: PASS.

### Task 6: Complete credential deletion and key-rotation lifecycle

**Files:** credential destroy service/settings/API tests; encryption rotation test and deployment documentation.

- [ ] **Step 1: Test deletion with live references**

Assert deletion nulls inventory defaults, clears encrypted credential fields before destroy, cancels unclaimed groups using it, requests cancellation of active groups, preserves historical names/fingerprints/events, and never exposes the deleted material. Race a claim against deletion and prove the row locks result in either a completed claim with cancellation requested or deletion before claim—not an unowned plaintext payload.

- [ ] **Step 2: Centralize destructive behavior**

Both Settings and API destroy actions call `CredentialDestroyer.call`. Lock credential, referencing inventories, and non-terminal groups in stable ID order. Apply null/cancel operations in one transaction, overwrite encrypted fields with nil, save, then destroy. Return counts for UI warning/confirmation but no group payload.

- [ ] **Step 3: Exercise primary-key rotation compatibility**

In a test-only encryption context, persist credential/variable/group payload with an old primary key, configure `[new_key, old_key]`, confirm decryption, update records to re-encrypt, remove old key, and confirm decryption with only the new key. Document operational steps in `docs/deployment/ansible.md`; never include real keys.

- [ ] **Step 4: Verify**

Run: `docker compose exec web bin/rails test test/services/control_center/ansible/credential_destroyer_test.rb test/config/active_record_encryption_rotation_test.rb test/integration/settings/ansible_credentials_test.rb test/integration/api/v1/control_center/ansible/credentials_test.rb`

Expected: PASS.

### Task 7: Add an optional disposable SSH smoke profile

**Files:**

- Create `ansible_executor/smoke/ssh_target/Dockerfile`
- Create `ansible_executor/smoke/ssh_target/entrypoint.sh`
- Create `ansible_executor/smoke/playbooks/check.yml`
- Create `ansible_executor/smoke/run.sh`
- Modify `docker-compose.yaml`
- Create `docs/deployment/ansible.md`

- [ ] **Step 1: Add an isolated test-only target**

Behind Compose profile `ansible-smoke`, build a minimal OpenSSH server with one unprivileged user and a generated-at-start test host key. Mount no host paths, publish no ports, and attach only a dedicated internal smoke network shared with the executor/web. Use test credentials generated for that run and delete them during teardown.

- [ ] **Step 2: Automate the smoke lifecycle**

`run.sh` must: start the profile; mint an Ansible-capable runner using Hunter's supported rake/API path; create a test credential through the app; create inventory/playbooks/variable sets; request scan; obtain the expected fingerprint directly from the disposable target as the out-of-band test oracle; confirm it; run syntax/connectivity; execute check mode and a harmless marker task; run sequential stop and continue groups; run bounded parallel groups; cancel a long-running test; assert terminal events/counts; assert payload purge; and tear down only named profile resources via a trap.

- [ ] **Step 3: Document production differences**

Document required encryption backup/rotation, runner-token minting, VPN CIDRs and firewall, host-key out-of-band verification, no published executor port, resource limits, health checks, upgrades of pinned Ansible packages, and the fact that the smoke target is never enabled in production.

- [ ] **Step 4: Execute smoke test**

Run: `bash ansible_executor/smoke/run.sh`

Expected: exit 0 with one successful single run, expected sequential/parallel outcomes, cancellation, redacted secret assertion, and teardown confirmation.

### Task 8: Final verification and handoff

- [ ] **Step 1: Check all shared integration diffs**

Inspect `git status --short` and diffs for routes, Control Center tabs/views, Settings, OpenAPI, Compose, and importmap registration. Preserve the concurrent Whiterabbit implementation and run its focused tests.

- [ ] **Step 2: Run every automated gate from a fresh build**

```bash
docker compose build web
docker compose --profile ansible build ansible-executor
docker compose up -d db mongo web
docker compose exec web bin/rails db:test:prepare
node --test web/test/javascript/*.mjs
python3 -m unittest discover -s ansible_executor/tests -v
docker compose exec web bin/rails test
docker compose exec web bin/brakeman --no-pager
docker compose exec web bin/rubocop
docker compose config --quiet
docker compose -f docker-compose.prod.yaml config --quiet
bash ansible_executor/smoke/run.sh
git diff --check
```

Expected: every command PASS, no new Brakeman warning, and no whitespace error.

- [ ] **Step 3: Perform final manual security/UX review**

Confirm sequential stop default and selectable continue, explicit parallel acknowledgement/cap, correct order, cancellation warning, retry-as-new IDs, output masking/truncation, raw-YAML warnings, host-key mismatch blocking, target CIDR rejection, no secret in API/browser/log/argv/database plaintext, executor cleanup, mobile/dark-mode behavior, keyboard modal operation, and no regressions in Whiterabbit Templates/Jobs/Statistics.

- [ ] **Step 4: Optional user-authorized final commit**

Only if the user explicitly requests a commit:

```bash
git add ansible_executor docs/deployment/ansible.md web/app web/config web/lib web/test .env.example docker-compose.yaml docker-compose.prod.yaml
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Add multi-playbook Ansible orchestration and hardening"
```
