# Hunter Assistant implementation checkpoint — 2026-07-26

Use this checkpoint with:

- `AGENTS.md`
- `docs/superpowers/specs/2026-07-25-hunter-assistant-security-design.md`
- `docs/superpowers/plans/2026-07-25-hunter-assistant-implementation.md`

## Operator decisions that remain binding

- Work inline in `/home/codex/workspace`; the user explicitly declined a worktree.
- Do not commit unless the user explicitly asks. No assistant work is committed yet.
- Preserve unrelated/user changes, especially the existing Compose port bindings changed to
  `0.0.0.0`.
- Portainer is not part of this project. It was mentioned only while discussing the threat
  model for file-mounted secrets.
- Provider and service credentials remain file-mounted secrets. Never print or source the
  repository `.env`; tests loaded only `DB_USERNAME` and `DB_PASSWORD` programmatically.
- Architecture remains browser/Rails -> RabbitMQ -> bounded Go gateway/provider -> fixed Go
  MCP broker -> sanitized Rails machine API. There is no agentic CLI, shell, generic HTTP
  tool, or direct gateway-to-Hunter route.

## Honest progress

- Tasks 1–13 are implemented in source. Task 13's Rails, MCP, gateway-evidence, and isolated
  Go validator portions are complete and their non-container test suites pass.
- Tasks 14–18 have not been implemented.
- Task 11 source is implemented and verified with Go tests/vet/static build, but its Docker
  image build and live Squid proxy test remain pending because this workspace has neither
  Docker nor Podman.
- Task 13's validator image build and live `ansible-playbook --syntax-check` container test
  are pending for the same environment reason. Do not mistake source/unit completion for
  container acceptance.
- Overall effort is approximately 60–65% complete. The later lifecycle, persistence,
  operations, Compose, and adversarial-gate tasks are substantial.

## Completed through Task 13

The repository now contains the approved security configuration, provider profiles,
encrypted assistant persistence, digest-only service identities and grants, metadata-only
audits, session-admin APIs, safe global chat shell, explicit context sanitizers, sanitized
machine API, non-durable RabbitMQ contracts/topology, fixed-catalog Go MCP broker, bounded Go
provider gateway, egress policy files, and effect-free Whiterabbit validation.

Whiterabbit validation is closed, fail-closed when its command allowlist is absent, reuses
the existing Control Center validator only after assistant-specific checks, returns redacted
stable errors, and does not persist/send/run anything.

## Task 13 completed implementation

Rails work:

- Migration `20260725010004_create_assistant_validation_requests.rb` and updated schema.
- `Assistant::ValidationRequest` with encrypted source/result, digest, grant/turn binding,
  expiry, and terminal source deletion.
- `Assistant::DraftValidation::AnsibleStatic` with a 64 KiB ceiling and default-deny module
  policy. It rejects shell/command/raw/script, roles, collections, include/import, lookups,
  environment injection, prompts, absolute paths, URLs, secret material, and existing unsafe
  connection constructs before dispatch. It additionally rejects `vars_files`, module
  defaults, plugin/dependency path keys, `include_vars`, and relative `..` path traversal so
  syntax parsing cannot be used to read container files.
- `Assistant::ValidationDispatcher` creates the request before transient publishing, emits
  the closed v1 validation job, ingests closed terminal events, deletes source, stores an
  encrypted normalized result, and records metadata-only completion audit data.
- Machine validation endpoints now support immediate static rejection, pending Ansible
  validation, grant-bound result retrieval, and Whiterabbit validation.
- `Assistant::EventConsumer` routes the validation-event queue to the validation dispatcher.
- Versioned Whiterabbit and Ansible authoring policies.

Validator worker:

- `assistant/validator/` is a dedicated Go 1.25 service pinned to
  `github.com/rabbitmq/amqp091-go v1.13.0`. It reads only the mode-0400 validator RabbitMQ
  password file and has no Hunter HTTP package, Hunter service token, provider SDK, generic
  command input, or user-controlled argv/filename.
- The closed job decoder rejects unknown fields, invalid IDs, stale/long expirations, NUL or
  invalid UTF-8 input, and source above 64 KiB.
- The worker consumes `assistant.validator.requests` with manual ack/QoS 1, requires JSON,
  publishes transient confirm-mode terminal events to `assistant.validation_events`, drops
  malformed jobs, and requeues only when terminal event publication fails.
- Each check creates a mode-0700 directory beneath `/work`, creates only private
  HOME/local/remote/tmp directories plus mode-0600 `playbook.yml`, supplies a complete fixed
  environment and fixed `/usr/bin/ansible-playbook --syntax-check --inventory localhost,
  playbook.yml` invocation, applies a 10-second deadline with process-group kill, caps both
  output streams at 32 KiB, returns stable codes only, and removes the workspace.
- `ansible.cfg` disables external role/collection/plugin paths and enables only the synthetic
  host-list inventory. The non-root Alpine image pins `ansible-core=2.20.0-r0` and
  `ca-certificates=20260611-r0`; both versions were rechecked against the official Alpine
  v3.23 package index on 2026-07-26.
- The validator health endpoint is status-only. Unit tests exercise exact workspace contents,
  source rejection, stable/redacted codes, output caps, cancellation, and a real subprocess
  deadline kill.

Gateway hardening added during Task 13:

- Strict OpenAI-compatible response schema: object root, every property required, unused
  branch values nullable.
- Strict function schemas require every object property.
- Validation results carry correlation ID, artifact type, terminal status, normalized data,
  and SHA-256 content digest.
- A final draft is rejected unless the exact content digest matches its validation evidence.
- An Ansible draft must cite terminal `get_validation_result` evidence, not the initial
  pending `validate_ansible_draft` call.
- Provider adapter tests exercise the two-call Ansible validation/result flow.
- MCP now validates the full closed Rails validation envelope, including nested details and
  normalized draft shape, and rejects unknown nested response fields before returning tool
  output to a provider.
- A real `Assistant::EventConsumer` routing test proves validator events reach terminal
  ingestion and are acknowledged only after the encrypted request is updated and source is
  cleared.

## Exact next step — begin Task 14 in TDD order

Do not revisit or expand Task 13 unless a regression appears. Begin Task 14, Step 1:

1. Create failing `web/test/integration/api/v1/assistant/turns_test.rb` and
   `web/test/services/assistant/turn_creator_test.rb` for session-admin ownership, resolved
   context disclosure, persist-before-dispatch, queued state, grant binding, and no raw grant
   in any browser response.
2. Create failing `web/test/javascript/assistant_controller_test.mjs` for polling/cancel and
   text-only rendering of adversarial HTML/script/control-character content.
3. Run the exact Task 14 Step 2 Rails/JavaScript command and observe the missing behavior.
4. Implement `Assistant::TurnCreator` transactionally: lock/verify the conversation and
   profile/settings, resolve at most ten selected context records, persist message/context/
   turn/audit and issue the grant before publishing. Publish only after commit; on failure,
   interrupt the turn and revoke the grant.
5. Add scoped create/show/cancel/draft endpoints, routes, OpenAPI coverage, 750 ms polling
   while open, backoff while closed, late-event rejection, and server-trusted validation
   cards. Never render model HTML and never add run/send/schedule controls.

Keep the Docker-limited Task 11 and Task 13 checks on the acceptance-gate list; they can run
when a Docker-compatible environment is available and must run no later than Task 17.

## Fresh verification evidence at this checkpoint

Run on 2026-07-26 after the latest changes:

- Rails: `928 runs, 3909 assertions, 0 failures, 0 errors, 0 skips`.
- JavaScript: `47 tests, 47 pass, 0 fail`.
- Gateway: `go test -race ./...`, `go vet ./...`, and a static binary build passed all six
  packages.
- MCP: `go test -race ./...`, `go vet ./...`, and a static binary build passed all broker
  packages, including the nested validation-envelope test.
- Validator: `go test -race ./...`, `go vet ./...`, and a static binary build passed all four
  packages.
- `go mod verify` passed for gateway, MCP, and validator.
- Focused RuboCop inspection of the Task 13 Rails files found no offenses.
- `gofmt -l` reported no changed Go files.
- `git diff --check` exited 0.

Rails tests require PostgreSQL at Docker gateway `172.17.0.1:5433`, database
`hunter_test`. Load only `DB_USERNAME` and `DB_PASSWORD` from `../.env` without printing
them, then set `DB_HOST`, `DB_PORT`, and `DB_DATABASE_TEST` before `bin/rails test`.

Go is not installed system-wide. This session used the checksum-verified official Go
1.25.12 tree at `/tmp/hunter-go-1.25.12/go`; a later session may need to download and verify
it again.

## Known gaps and warnings

- Docker/Podman is unavailable here, so neither the gateway/egress nor validator image has
  been built and no live proxy, Ansible, or container-network test has run.
- The full Rails suite currently prints a disposable raw token from an existing API-token
  rake test. Do not copy the value into logs or this checkpoint. Capture/suppress that output
  before the Task 18 secret-leak gate.
- The full Rails run emitted expected Mongo connection warnings while tests exercised the
  read-failure fallback; the suite still passed.
- No live provider key or provider endpoint was used. Provider tests use local TLS mocks.
- The production feature must remain disabled until Task 18 external review and explicit
  operator enablement.

## Remaining plan after completed Task 13 source

- Task 14: turn creation/cancel/polling, disclosure UI, safe draft cards.
- Task 15: shared Control Center persistence and CSRF-protected confirmed save.
- Task 16: retention, database-backed rate limits, and kill switch.
- Task 17: Compose secrets, least-connectivity networks, runtime hardening, images, and local
  integration.
- Task 18: adversarial end-to-end, network denial, supply-chain/secret gates, rotation drill,
  documentation, and independent production review.

Do not mark the overall development done at this checkpoint.
