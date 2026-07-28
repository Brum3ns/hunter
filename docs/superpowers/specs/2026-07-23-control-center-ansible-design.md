# Hunter Control Center — Ansible Automation Design

**Date:** 2026-07-23

**Status:** Approved

**Module:** Control Center / Ansible

**Scope:** Raw playbook and inventory authoring, encrypted credentials and
variables, isolated execution, run history, multi-playbook groups, and playbook
import/export.

## 1. Goal

Add an **Ansible** tab to Hunter's existing Control Center so its single trusted
administrator can author raw Ansible playbooks and inventories, manage reusable
variables and SSH credentials, and run automation against worker VPSs reachable
over the deployment's VPN.

Hunter remains the control plane and source of truth. A dedicated, isolated
executor is the only component that opens SSH connections to workers. The design
must make later additions—structured inventory forms, guided playbook builders,
schedules, workflow dependencies, additional executors, and richer project
bundles—incremental rather than requiring a rewrite.

## 2. Context and settled decisions

Hunter already has a Control Center with Whiterabbit Templates, Jobs, and
Statistics. The Ansible capability is a sibling within that department, not an
extension of Whiterabbit's models or execution path.

The following decisions were made during design:

- Use Hunter-native models and APIs with a dedicated Ansible executor. Do not
  run Ansible in the Rails web process and do not introduce AWX.
- Start with raw YAML editors for both playbooks and inventories. Structured
  builders are future enhancements.
- Store SSH credentials in Hunter from the start, protected with Active Record
  Encryption.
- Provide reusable named variable sets. Encrypt every managed variable value;
  a separate `secret` flag controls display and redaction behavior.
- Keep connection credentials separate from ordinary Ansible variables.
- Preserve Hunter's current single trusted-admin model. No RBAC is added in this
  pass, although ownership fields remain explicit for future authorization.
- A launch may contain one or multiple playbooks against a shared inventory.
  Sequential execution is the default; parallel execution is an explicit
  option with a concurrency cap and warning.
- Sequential groups default to stopping after the first failed playbook. The
  admin may choose to continue remaining playbooks instead.
- Support editor-local single-file upload/download, persistent multi-file
  import by picker or drag-and-drop, and ZIP download of selected playbooks.

## 3. Non-goals

- No visual playbook builder or structured host/group inventory form.
- No AWX dependency or duplicated AWX user interface.
- No arbitrary user-supplied Ansible CLI string.
- No custom collection, role, plugin, or full project-bundle upload in v1.
- No Ansible Vault-encrypted YAML input in v1. Hunter-managed encrypted
  variables cover the initial secret-variable use case.
- No schedules, approvals, workflow dependency graph, or recurring runs.
- No automatic retry of a partially executed playbook.
- No multi-credential inventory in v1. A run uses one SSH credential, normally
  the inventory default, with an optional launch-time override.
- No export of credentials or variable sets.
- No ZIP import. Bulk import accepts selected or dropped `.yml`/`.yaml` files;
  a downloaded ZIP must be extracted before re-import.

## 4. Architecture and boundaries

### 4.1 High-level flow

```text
Browser
  │ session-authenticated web/API requests
  ▼
Hunter Rails control plane ── PostgreSQL
  │                             playbooks, inventories, encrypted secrets,
  │ queue/claim API             run groups, runs, and redacted events
  ▼
Dedicated ansible-executor
  │ SSH only to configured VPN CIDRs
  ▼
Worker VPS fleet
```

The browser creates and observes work; it never receives stored secret values.
Rails authenticates and authorizes the administrator, validates content, stores
encrypted data, queues runs, and ingests events. The executor claims work using
a scoped machine identity, receives a just-in-time execution payload, runs
Ansible Runner in a temporary workspace, and reports events and results.

### 4.2 Namespace and code organization

- Models and domain services: `ControlCenter::Ansible::*`
- Browser/API controllers: `Api::V1::ControlCenter::Ansible::*`
- Web controllers and views: `ControlCenter::Ansible::*` and
  `app/views/control_center/ansible/`
- JavaScript controllers/libraries: Ansible-specific files under the existing
  Control Center convention
- Executor agent: a dedicated top-level `ansible_executor/` application and
  image, independent from the curl runner

Whiterabbit's `ControlCenter::Template`, `ControlCenter::Job`, services, API,
and JavaScript remain unchanged except for shared presentation primitives that
can be safely extracted after concurrent work has settled.

### 4.3 Web navigation

Add **Ansible** as one Control Center department tab at
`/control_center/ansible`. Inside it, secondary navigation exposes:

1. Playbooks
2. Inventories
3. Variable Sets
4. Runs

SSH credentials are managed in Settings under a new Ansible Credentials
section. The Ansible tab links directly to that section when no usable
credential exists or when the admin chooses “Manage credentials.”

## 5. Domain model

All Ansible tables live in PostgreSQL. Exact migration types and indexes are
pinned in the implementation plan, but the ownership and persistence boundaries
below are normative.

### 5.1 `ControlCenter::Ansible::Playbook`

Stores one raw Ansible playbook:

- unique `name`
- optional `description`
- `yaml_content`
- content checksum
- creator reference and timestamps

The name is Hunter metadata; a standard Ansible playbook does not need to carry
it inside the YAML. Runs snapshot the saved YAML so later edits do not alter
history.

### 5.2 `ControlCenter::Ansible::Inventory`

Stores one raw YAML inventory:

- unique `name`
- optional `description`
- `yaml_content`
- optional default credential
- approved `known_hosts` content and fingerprint metadata
- creator reference and timestamps

One credential is used per run in v1. Host/group-specific credential bindings
can be added later without changing playbooks, credentials, or run events.

### 5.3 `ControlCenter::Ansible::Credential`

A named SSH connection identity:

- unique `name`
- authentication type: `private_key` or `password`
- SSH username
- encrypted private key
- encrypted SSH password
- encrypted private-key passphrase
- encrypted privilege-escalation password
- derived public-key fingerprint where applicable
- creator reference, last-used timestamp, and timestamps

Secret fields use non-deterministic Active Record Encryption. They are never
query keys and never use deterministic encryption. API reads expose metadata,
fingerprints, and booleans such as `private_key_configured`; they never serialize
secret values.

Deleting a credential clears its secrets, nulls inventory defaults, cancels
unclaimed groups that selected it, and requests cancellation of active groups
that selected it. It cannot retract material already held by a running process,
so the UI states that active cancellation is best-effort. Historical runs remain
intact through their metadata snapshots.

### 5.4 `ControlCenter::Ansible::VariableSet` and `Variable`

A variable set is a reusable named collection with a description and creator.
It has ordered variables containing:

- unique name within the set
- value type: string, number, boolean, list, or dictionary
- encrypted serialized value
- `secret` display/redaction flag
- position and timestamps

Every value is encrypted, not only values marked secret. Non-secret values may
be returned to the authenticated admin for editing; secret values are write-only
and return only a configured marker.

Ordered join records attach variable sets to any number of playbooks and
inventories. Launch-time selections can add more sets without mutating those
defaults.

### 5.5 `ControlCenter::Ansible::RunGroup`

Every launch creates a group, including a launch with one playbook. This avoids
separate single- and multi-playbook execution paths.

A group stores:

- execution mode: `sequential` or `parallel`
- sequential failure policy: `stop` or `continue`
- bounded parallel concurrency
- selected inventory, credential, variable-set references, host limit, check
  mode, and timeout
- creator reference, aggregate status, cancellation request, and timestamps
- an encrypted, ephemeral execution payload containing the exact resolved
  variables and credential material required by queued children

The ephemeral payload prevents edits or credential rotation after launch from
changing a later sequential step. It is cleared after all children are terminal,
after cancellation becomes terminal, or after claim timeout. Audit data retains
only non-secret resolved variables, secret variable names, source references,
and the selected credential's name and public fingerprint.

Group states are `queued`, `running`, `succeeded`, `failed`,
`partially_succeeded`, `canceling`, and `canceled`. `succeeded` means every child
succeeded. `failed` means at least one child failed and none succeeded.
`partially_succeeded` means the terminal children contain both successes and
failures/skips. An administrator-requested cancellation produces `canceled`
after all active children stop, even when earlier children had succeeded.

### 5.6 `ControlCenter::Ansible::Run`

One ordered child of a run group and one immutable playbook execution:

- group, playbook, and step position
- playbook and inventory YAML snapshots
- selected variable-set metadata and non-secret resolved-variable snapshot
- credential name/fingerprint snapshot
- status, error code/detail, exit status, counts, truncation marker, and timing
- claimed executor, lease identifier, lease expiry, and heartbeat timestamp

Child states are:

```text
waiting → queued → validating → running → succeeded
                                   ├────→ failed
                                   └────→ canceling → canceled

waiting/queued ────────────────────────────────→ canceled or skipped
```

For a single-playbook launch, the child starts queued. A sequential group's first
child starts queued and later children start waiting. A scheduler promotes later
children according to order and failure policy. A parallel scheduler promotes
up to the group concurrency cap.

### 5.7 `ControlCenter::Ansible::RunEvent`

Stores ordered, redacted Ansible Runner events:

- run and executor references
- Ansible event UUID and parent UUID
- monotonic counter
- event type, play, task, host, and timestamps
- redacted stdout and structured event data
- truncation marker

The event UUID is unique within a run so executor retries are idempotent. Large
payloads are capped before persistence.

### 5.8 Executor utility work

Syntax validation, host-key scans, and connectivity tests also need executor
isolation but are not playbook history. A small `ExecutorTask` queue stores these
bounded utility operations, their status, result, lease, expiry, and creator.
The executor claims utility work before ordinary runs with fairness limits so a
large validation burst cannot starve executions.

## 6. Encryption and secret lifecycle

### 6.1 Application encryption configuration

Generate a standard Rails key set using `bin/rails db:encryption:init` and
configure:

- `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`
- `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY`
- `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT`

Production values live in deployment secrets or encrypted Rails credentials,
never in Git or PostgreSQL. Production boots fail closed if any required value
is absent. Development and test use explicit non-production keys.

The primary key is backed up separately from database backups. Rotation uses
Rails' supported primary-key list: add the new key, re-encrypt records, verify,
then retire the old key. No attribute in this design relies on deterministic
encryption, so rotation does not inherit deterministic-encryption limitations.

### 6.2 Secret handling rules

- Secret form fields are write-only. Blank updates retain the stored value;
  replacement and deletion are explicit operations.
- Encrypted attribute names and request aliases are included in Rails parameter
  filtering.
- Normal browser and API serializers never include secret values.
- Secret material is absent from URLs, command arguments, run audit snapshots,
  exception details, and application logs.
- The machine-only claim response is the sole API response allowed to contain a
  decrypted run payload. The atomic claim assigns the Ansible executor and
  establishes the lease before returning that response; later machine writes
  require the same executor and lease.
- A same-stack executor may use the private Compose network. Any executor outside
  that network must use HTTPS.
- The executor holds secrets only in memory and its per-run mode-`0700` tmpfs
  workspace. Cleanup runs on success, failure, timeout, cancellation, and normal
  signal handling.
- The encrypted ephemeral group payload is purged whenever the group becomes
  terminal or expires before execution.

### 6.3 Variables and output disclosure

Hunter-managed secret variables are injected as Ansible extra variables at run
time. Ansible variable precedence, from lowest to highest for Hunter-controlled
sources, is:

1. playbook defaults and variables inside the playbook
2. inventory/group/host variables
3. variable sets attached to the inventory
4. variable sets attached to the playbook
5. variable sets selected at launch
6. launch-time overrides

Hunter resolves levels 3–6 deterministically, rejecting duplicate names at the
same level. The resulting extra-variable payload intentionally overrides lower
Ansible sources.

The executor redacts exact known secret strings before sending events, and Rails
repeats redaction before persistence. This applies to stdout and structured event
fields but cannot reliably detect transformed, encoded, or hashed derivatives.
The editor therefore warns that tasks consuming secrets must use `no_log: true`.
Raw playbook execution is available only to Hunter's trusted administrator.

Connection fields such as `ansible_password`, `ansible_become_password`, private
key contents, and equivalent aliases are rejected in playbook, inventory, and
ordinary variable input. Connection secrets come only from a selected
credential.

Playbook and inventory YAML are not encrypted. They must reference Hunter
variables instead of containing literal secrets. Validation detects known secret
fields and private-key formats, but cannot identify every arbitrary secret
string; the editor and export flow therefore carry a persistent warning against
embedding credentials, tokens, or passwords in raw YAML.

## 7. Validation and execution safety

### 7.1 YAML and schema validation

Hunter performs fast validation before saving:

- case-insensitive `.yml`/`.yaml` extension checks for imported files
- byte, nesting, and collection-count limits
- safe YAML parsing with no arbitrary Ruby objects
- playbook root and play/task structural checks
- inventory root, host, group, and connection-variable checks
- variable-name and typed-value validation
- rejection of embedded private keys and reserved connection-secret variables
- rejection of Ansible Vault/custom YAML tags in v1

Inventory may define host aliases, `ansible_host`, and `ansible_port`. The SSH
username and authentication material come from the selected Hunter credential;
inventory cannot override them in v1.

The executor performs an authoritative `ansible-playbook --syntax-check` in the
same pinned environment used for execution. The Validate action runs this check
as an isolated executor task. Every real run repeats it before SSH.

### 7.2 Executor and local-execution isolation

The executor image contains pinned versions of Ansible Runner, ansible-core,
OpenSSH, and the approved collections. V1 playbooks receive no uploaded custom
plugins, roles, or executable project files.

Static validation rejects explicit local connection plugins, `local_action`,
and explicit delegation to localhost/the executor. The executor also runs as a
non-root user with a read-only root filesystem, a per-run tmpfs, dropped Linux
capabilities, no-new-privileges, resource limits, a sanitized environment, and
no host filesystem mounts. Container isolation remains the containment boundary
for dynamically constructed behavior that static YAML inspection cannot prove.

Ansible is launched with a fixed executable and discrete argv values. Hunter
does not expose a free-form command-line field. Timeouts, forks, output limits,
host limits, check mode, inventory path, and playbook path are typed options.

### 7.3 VPN target restriction

Production requires one or more `ANSIBLE_ALLOWED_CIDRS` values. Before SSH, the
executor resolves every target and rejects any address outside those networks.
Generated execution inventory pins the approved resolved address while
preserving the original inventory alias. An egress firewall should additionally
restrict the executor to Hunter and TCP/22 on those VPN networks.

### 7.4 SSH host keys

Strict host-key checking is always enabled. Inventories store approved
`known_hosts` entries and fingerprints.

The admin may request a host-key scan through the executor. Scan results are
displayed as untrusted candidates and must be compared with an expected
fingerprint obtained out of band, then explicitly confirmed before storage.
Hunter never silently trusts a first connection or automatically replaces a
changed host key. A mismatch blocks execution before authentication.

## 8. Executor protocol and run lifecycle

### 8.1 Machine identity

Reuse Hunter's digest-only `Runner` identity model with an `ansible` capability.
The Settings UI and model expose supported runner kinds from one centralized
allowlist rather than coupling them to curl jobs. An Ansible executor token
cannot claim curl work, and a curl-only runner cannot observe Ansible payloads.

### 8.2 Claim and lease

The executor uses machine-only endpoints to:

1. claim utility tasks or the oldest eligible queued run atomically
2. receive a random lease identifier and lease expiry
3. submit periodic heartbeats
4. submit idempotent event batches
5. poll cancellation state
6. submit an idempotent terminal result

Claims use PostgreSQL row locks with `FOR UPDATE SKIP LOCKED`. Every later write
requires both the owning executor and current lease. A stale or superseded lease
cannot append events or finalize a run.

### 8.3 Execution sequence

For a playbook run, the executor:

1. Claims the run and creates its private tmpfs workspace.
2. Receives and materializes the immutable playbook/inventory snapshots,
   resolved variables, known hosts, and selected credential.
3. Re-resolves and validates target addresses against allowed VPN CIDRs.
4. Runs the authoritative syntax check.
5. Transitions the run to `running` and starts Ansible Runner.
6. Batches structured events to Hunter while sending heartbeats.
7. Observes cancellation requests and terminates the entire Ansible process
   group, escalating to kill after a grace period.
8. Posts the terminal result and summary.
9. Removes the workspace and all materialized secrets.

The executor buffers unsent events only in its tmpfs during temporary API
failures and retries with bounded backoff.

### 8.4 Timeouts and stale work

- A queued run not claimed before the configured claim timeout fails as
  `executor_unavailable`.
- A validating/running run whose lease expires fails as `executor_lost`.
- Stale work is never automatically rerun because remote state may already have
  changed.
- Retry always creates a new group/run with a new audit identity and a launch
  dialog prefilled from non-secret prior selections.

## 9. Multi-playbook groups

The launch dialog permits ordered selection of one or more playbooks against one
shared inventory, credential, variable selection, host limit, check-mode flag,
and timeout policy.

### 9.1 Sequential mode

- Default mode.
- Runs one child at a time in selected order.
- Default `stop` policy marks remaining waiting children `skipped` after the
  first failure.
- Optional `continue` policy promotes the next child after a failure.
- Group aggregation follows the explicit status definitions in the domain
  model while retaining every child outcome.

### 9.2 Parallel mode

- Explicit selection with a warning about package locks, services, files, and
  reboots on shared hosts.
- Bounded by the lesser of the launch value and
  `ANSIBLE_MAX_PARALLEL_PLAYBOOKS`, default 3.
- Parallel mode continues promoting selected children within the cap and
  collects every child's result; the sequential stop/continue selector is
  disabled.
- Ordinary Ansible `forks` limits remain separate from the number of playbooks
  run concurrently.

### 9.3 Group cancellation and progress

Canceling a group cancels waiting/queued children and requests cancellation of
active children. The group detail shows aggregate progress plus each child's
independent validation, events, result, and retry action.

## 10. Browser and API surface

### 10.1 Human-facing JSON API

All controllers subclass `Api::V1::BaseController`, use the Control Center API
scope, and retain Hunter's cookie/CSRF and bearer-token behavior.

The resource surface is rooted at `/api/v1/control_center/ansible`:

- playbook index/show/create/update/destroy and validation
- playbook selected export
- inventory index/show/create/update/destroy and validation
- inventory host-key scan/confirm and connectivity test
- credential metadata/create/update/destroy
- variable-set CRUD and nested variable CRUD
- run-group index/show/create/cancel
- child-run show/cancel and paginated events
- executor health/last-seen summary

Bulk import intentionally reuses individual validate/create/update endpoints so
each file can succeed or fail independently. Selected export is the one
non-JSON response: a CSRF-protected ZIP stream.

### 10.2 Machine-only API

Machine endpoints are under an Ansible executor namespace and authenticate
against an `ansible`-capable `Runner`, not `ApiToken`:

- claim utility work
- report utility result
- claim run
- submit heartbeat
- check control/cancellation state
- submit event batch
- submit terminal result

Machine endpoints use stable error envelopes, strict ownership checks, body-size
caps, and idempotency constraints.

## 11. User experience

### 11.1 Playbooks

A split view mirrors the existing Control Center authoring pattern: searchable
playbook list on the left and raw YAML editor on the right. Actions are New,
Validate, Save, Run, Duplicate, Delete, Upload YAML, and Download YAML.

The Run dialog provides ordered playbook selection, sequential/parallel mode,
failure policy where applicable, inventory, credential override, additional
variable sets, temporary typed overrides, optional host limit, check mode,
timeout, and bounded concurrency.

### 11.2 Inventories

Inventories use the same list/editor shell for raw YAML. The editor includes
default credential selection, fast validation, isolated validation,
connectivity testing, host-key scanning, and explicit fingerprint confirmation.

### 11.3 Variable sets

Variable sets use a list plus ordered typed key/value editor. Secret inputs are
write-only and masked after saving. Structured list/dictionary values accept a
safe YAML/JSON fragment and show normalized validation errors.

### 11.4 Runs

Runs show group history and detail. A detail page presents aggregate group
status, ordered children, play/task/host event stream, changed/failed/unreachable
counts, duration, redacted stdout, truncation state, cancellation, and retry.
Browser updates use polling initially, consistent with Hunter's existing runner
UI; transport can later change without altering the run model.

### 11.5 Settings credentials

The Ansible Credentials settings section lists name, authentication type,
username, fingerprint/configuration state, last used, and timestamps. Create and
edit forms accept the appropriate write-only secrets. Destructive removal uses
explicit confirmation and warns when inventories reference the credential.

## 12. Playbook import and export

### 12.1 Single-file authoring

- Editor **Upload YAML** reads one `.yml`/`.yaml` into the editor as an unsaved
  draft.
- Editor **Download YAML** downloads the current contents with a sanitized
  playbook-derived filename.

### 12.2 Persistent bulk import

The Playbooks toolbar has **Import YAML** with a multi-select file input. Dragging
files over the Playbooks section shows a stable full-section overlay; dropping
starts the same importer.

The browser reads files locally and sends YAML through authenticated JSON APIs.
No multipart storage or uploaded source file remains on the server.

Processing is sequential and independent per file:

1. Validate extension and per-file/batch limits.
2. Read the file.
3. Derive and normalize Hunter's playbook name from the filename.
4. Call Ansible playbook validation.
5. Create a new playbook or resolve a name conflict.
6. Record a terminal per-file result and continue.

Conflict choices are **Update**, **Update all**, **Skip**, and **Skip all**. An
“all” choice applies only to the current batch. Duplicate derived names inside
one batch conflict deterministically; if updated, the later file wins.

The progress dialog shows waiting, validating, imported, updated, skipped, and
failed states and a final summary. User-controlled text is inserted with DOM
`textContent`.

Default limits are 256 KiB per playbook, 100 files, and 10 MiB per batch, all
configurable.

### 12.3 Selected bulk export

Playbook rows have checkboxes and select-all-visible. **Download selected** posts
selected IDs to a CSRF-protected export endpoint. Hunter streams a ZIP generated
with the existing `rubyzip` dependency:

- one exact saved `.yml` file per selected playbook
- sanitized deterministic filenames
- numeric suffixes for sanitized-name collisions
- no credentials, variable sets, run data, or server paths

ZIP creation uses a bounded temporary file/stream that is removed immediately
after response completion. Import does not extract archives, eliminating ZIP
path traversal from the upload surface.

## 13. Error handling

Expected errors are explicit and safe to display:

- invalid/unsafe YAML or typed value: `422 unprocessable_entity`
- missing record: Hunter's standard `404 not_found`
- missing credential, secret, known host, or variable: reject before queueing or
  fail validation before SSH with a stable code
- target outside allowed VPN ranges: `target_not_allowed`
- changed/unapproved host key: `host_key_untrusted`
- syntax failure: `syntax_invalid`
- SSH authentication failure: per-host `authentication_failed`
- unreachable host: per-host `unreachable`
- no executor claims in time: `executor_unavailable`
- lease/heartbeat expiry: `executor_lost`
- process timeout: `execution_timeout`
- user cancellation: terminal `canceled`
- output cap: cap one event at 64 KiB and stored event data for one run at 20
  MiB by default; preserve the first 75% and final 25% of an oversized text field
  with an inserted truncation marker, stop persisting verbose stdout after the
  run cap, retain summary/status events, and mark the affected records
  `truncated`

One failed import file does not fail its batch. A run failure does not become an
uncaught Rails 500. Failed writes use Hunter's normal validation or upstream
error envelopes without including secrets.

## 14. Testing

### 14.1 Encryption and models

- Persisted ciphertext does not contain plaintext credentials or variables.
- Encrypted fields decrypt correctly with configured test keys.
- Secret serializers expose only configuration markers.
- Blank updates retain secrets; explicit replacement/deletion behaves exactly.
- Associations, ordering, snapshots, ephemeral-payload purge, and credential
  deletion preserve audit history.
- Primary-key rotation compatibility is exercised with current and previous
  test keys.

### 14.2 Validation and services

- Safe parsing, schema, size/depth/count limits, reserved secret names, unsafe
  YAML tags, local execution, and inventory connection restrictions.
- Variable precedence, types, duplicate handling, secret/non-secret audit
  snapshots, and exact-value redaction.
- Filename normalization, duplicate export filenames, ZIP membership, and ZIP
  cleanup.
- Group scheduling for sequential stop/continue and bounded parallel modes.

### 14.3 API integration

- Cookie auth + CSRF and scoped bearer behavior.
- Credential and secret-variable write-only behavior.
- CRUD and validation for every human-facing resource.
- Run/group creation, ownership, cancellation, pagination, and retry-as-new.
- Executor token scoping, atomic claim, lease ownership, heartbeats, duplicate
  events, idempotent finalization, and stale leases.
- ZIP export headers/content and selection validation.

All external execution, SSH, and Ansible processes are doubled in Rails tests.

### 14.4 Executor tests

Use fake Hunter HTTP responses and a fake Ansible Runner process to cover:

- token normalization and authentication failures
- workspace permissions and cleanup on every exit path
- payload materialization without logging secrets
- CIDR and host-key enforcement
- syntax-check failure before SSH
- event batching/retry, heartbeat, lease rejection, output caps
- cancellation of the process group and forced-kill fallback
- transient API failure and bounded tmpfs buffering

### 14.5 JavaScript and web tests

- Focused integration markup tests for each Ansible secondary section.
- DOM-independent JavaScript unit tests for multi-file import state,
  validation failures, conflicts, update/skip-all policies, and summary counts.
- Selection/export controller tests where practical without adding a new JS
  package manager dependency.
- Browser smoke checks for editor behavior, drag overlay stability, modal focus,
  dark mode, responsive layout, secret masking, run polling, and cancellation.

### 14.6 End-to-end smoke profile

An optional non-production Compose profile provides a disposable SSH target and
test credential. It verifies encrypted credential storage, host-key approval,
VPN/CIDR checks, syntax validation, check mode, execution, event ingestion,
sequential/parallel groups, cancellation, and cleanup without contacting a real
VPS.

## 15. Deployment configuration

Production adds:

- the three Active Record encryption secrets
- `ansible-executor` image and service
- an Ansible-capable Runner token
- `ANSIBLE_ALLOWED_CIDRS`
- claim, lease, heartbeat, execution, cancellation, and output limits
- `ANSIBLE_MAX_PARALLEL_PLAYBOOKS` with default 3
- Ansible forks and executor job concurrency limits
- pinned Ansible/collection versions
- routing/firewall access from executor to Hunter and approved VPN TCP/22 only

The executor publishes no ports. It runs non-root with a read-only root
filesystem, tmpfs workspace, dropped capabilities, no-new-privileges, memory/PID
limits, and restart policy consistent with the existing runner.

## 16. Delivery stages

Implementation proceeds in independently testable stages:

1. Active Record Encryption foundation and Ansible credential settings.
2. Playbooks, inventories, variable sets, fast validation, and browser APIs.
3. Executor image/protocol, utility tasks, single-run lifecycle, events,
   cancellation, health, and stale-work handling.
4. Ansible tab user interface and run inspection.
5. Multi-playbook run groups with sequential/parallel modes and failure policy.
6. Single/bulk playbook import and selected ZIP export.
7. Full security regression and optional end-to-end smoke profile.

Each stage must pass its focused tests and the existing Control Center/full Rails
suite before the next stage begins.

## 17. Concurrent-work boundary

Another contributor is actively changing the Whiterabbit Templates page for
bulk import. Ansible implementation must inspect the worktree before every
shared-file edit, preserve those changes, and avoid modifying the contributor's
new JavaScript importer, tests, views, or plan/spec files.

The only unavoidable shared integration points are Control Center tab metadata,
routes, Settings composition, importmap pins where required, OpenAPI composition,
Docker/Compose configuration, and database schema. Those edits happen after the
corresponding concurrent files stabilize and receive focused regression tests.

Interaction conventions from Whiterabbit import—drag overlay, sequential
progress, and conflict decisions—should be reused conceptually. Ansible owns its
own importer and validation because its filenames and YAML schema differ.
