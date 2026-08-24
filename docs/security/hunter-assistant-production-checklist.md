# Hunter Assistant production security checklist

This is a release evidence record, not an enable switch. Keep
`ASSISTANT_ENABLED=false` until every required field is complete, every attached
artifact corresponds to the exact candidate image digest, and the independent
Reviewer records an explicit enable decision. Never place a raw credential,
credential digest, prompt, response, selected-record body, draft body, or tool
result in this document or its attachments.

The active direct-provider design is
`docs/superpowers/specs/2026-08-13-assistant-direct-provider-selection-design.md`
as amended by
`docs/superpowers/specs/2026-08-15-assistant-codex-mcp-boundary-design.md`,
`docs/superpowers/specs/2026-08-19-assistant-mcp-administrator-proxy-design.md`,
and
`docs/superpowers/specs/2026-08-23-unrestricted-whiterabbit-command-authoring-design.md`.
Use `docs/runbooks/assistant-codex-mcp-smoke-test.md` for the operator evidence
procedure. Legacy gateway/provider-key rows apply only when a separately
approved rollback candidate activates the `legacy-gateway` profile.

## Candidate and ownership

- Release/candidate identifier: **UNSET**
- Source commit: **UNSET**
- Review date (UTC): **UNSET**
- Deployment/operator owner: **UNSET**
- Security Reviewer (independent of implementation): **UNSET**
- Reviewer organization/contact record: **UNSET**
- Threat-model/design version reviewed: **UNSET**
- Open Critical findings: **UNSET — must be 0**
- Open High findings: **UNSET — must be 0**

## Provider and retention approval

Complete one row for each fixed direct backend. Provider retention, training
use, residency, abuse-monitoring access, subscription/contract eligibility,
and Hunter's intended data classification must be reviewed. An unapproved
backend keeps the whole Assistant disabled; there is no browser profile or
model override.

| Backend | CLI/auth boundary | Retention posture/evidence | Training use | Residency | Subscription owner + approver/date | Approved |
|---|---|---|---|---|---|---|
| OpenAI / Codex | ChatGPT device auth; `codex-cli 0.144.4`; no API key | UNSET | UNSET | UNSET | UNSET | No |
| Anthropic / Claude Code | Subscription login; Claude Code `2.1.220`; no API key | UNSET | UNSET | UNSET | UNSET | No |

## Immutable image inventory

Record registry references by immutable `sha256:` digest. Tags alone are not
acceptable. The digest must match the image used for tests, SBOM generation,
scanning, and deployment.

| Component | Registry reference with digest | Build provenance | Signature/attestation verified |
|---|---|---|---|
| Web | UNSET | UNSET | No |
| Hunter MCP | UNSET | UNSET | No |
| Assistant Codex | UNSET | UNSET | No |
| Assistant Claude | UNSET | UNSET | No |
| Legacy gateway (rollback candidate only) | N/A unless rollback is approved | UNSET | No |
| Legacy validator (rollback candidate only) | N/A unless rollback is approved | UNSET | No |

## Verification artifacts

Store artifacts in the approved release-evidence system and record identifiers,
checksums, tool versions, execution times, and pass/fail status. Do not link to
mutable “latest” results.

| Gate | Required evidence | Artifact/checksum | Result |
|---|---|---|---|
| Rails, JavaScript, Go race suites | Complete logs | UNSET | Not run |
| MCP conformance and adversarial fixtures | Complete logs | UNSET | Not run |
| Administrator-equivalent Hunter MCP operations | Exact 70-tool catalog parity across Rails/MCP/Codex/Claude; all 139 public and 47 internal API operations classified; no secret/delete/governance/machine-identity/generic proxy exposure; closed schemas, live revocation, effect/launch budgets, idempotent receipts, human attribution, and metadata-only audit verified with adversarial fixtures | UNSET | Not run |
| Codex 0.144.4 model-visible schema capture | Exact eight approved built-in names and complete stable schemas; no ninth tool | UNSET | Not run |
| Deferred Hunter MCP catalog capture | Sole source `hunter`; exact reviewed tool names/input schemas; exact service bearer and per-turn grant headers | UNSET | Not run |
| Codex immutable-workspace patch denial | Real pinned binary receives provider-forced `apply_patch`; failed custom-tool output observed; target remains absent | UNSET | Not run |
| Direct runner login persistence | Codex ChatGPT device auth and Claude subscription auth survive restart without volume recreation | UNSET | Not run |
| Direct runner stable errors | Login-required, timeout/unreachable, malformed response, usage limit where applicable; no raw provider/CLI output | UNSET | Not run |
| Resolved development/production Compose | Redacted configs | UNSET | Not run |
| Runtime hardening/seccomp (Docker default AppArmor) | Verification output | UNSET | Not run |
| Network denial | DNS and direct-IP denial output | UNSET | Not run |
| Secret leakage | Git/history/config/log/layer/SBOM scan output | UNSET | Not run |
| Dependency audit | Brakeman, bundle-audit, govulncheck | UNSET | Not run |
| Image vulnerability scan | Critical/High fail-closed report | UNSET | Not run |
| CycloneDX SBOM | One per candidate image | UNSET | Not run |
| SPDX SBOM | One per candidate image | UNSET | Not run |
| Credential rotation drill | Old rejection/new health output | UNSET | Not run |
| Live direct-provider `docker compose up` acceptance | Both logins absent/present, both one-click backends, resume, legacy read-only plus `legacy_provider_retired`, and redacted `docker compose config` review; config expands live secret values, so never attach it unredacted | UNSET | Not run |
| Metadata-only audit/log canaries | Unique prompt/reply/grant/login/tool canaries absent from audit metadata, logs, and API errors; expected message bodies present only in transcript storage | UNSET | Not run |
| Direct-provider rollback | Kill switches off, grants revoked, previous approved digests plus `legacy-gateway` profile restored as one candidate, history/session bindings unchanged | UNSET | Not run |
| Administrator-equivalent operational access through Hunter MCP — see `docs/superpowers/specs/2026-08-19-assistant-mcp-administrator-proxy-design.md` and the "Approved exceptions" entry in `AGENTS.md` | Evidence that: message submission authorizes only dedicated currently enabled tools; validators reject structurally invalid command content, disallowed Ansible modules, and secret fixtures with no mutation; create conflicts never overwrite; edits require current versions; job submissions and Ansible launch/cancel are idempotent and bounded; operational/tool/module/effect gates revoke live; all effects are human-attributed and metadata-only audited; no secret, delete, governance, machine callback, or generic request/execution tool is advertised or callable | UNSET | Not run |
| Unrestricted Whiterabbit command authoring and execution — see `docs/superpowers/specs/2026-08-23-unrestricted-whiterabbit-command-authoring-design.md` and the "Approved exceptions" entry in `AGENTS.md` | Evidence that: arbitrary-command browser and Assistant validation, create, edit, and job submission paths pass while structural validation and secret-input detection remain enforced; exact Rails/MCP/Codex/Claude catalog parity proves no generic tool was introduced; live Codex and Claude runs use an active scanner and another installed binary that was absent from the former allowlist; template-write and job-submit gates revoke immediately, receipts remain idempotent, effects remain human-attributed, and audits remain metadata-only; Whiterabbit worker identity, capabilities, mounts, environment-variable names, reachable networks, and installed binaries are reviewed; command, template, job, and secret canaries do not leak into Assistant audits, logs, errors, or projections; authorized-target and rollback records are attached; and an independent Reviewer explicitly accepts arbitrary worker execution and the residual destruction/exfiltration risk | UNSET | Not run |
| Direct conversation organization (rename + reorder) — see `docs/superpowers/specs/2026-08-13-assistant-conversation-workspace-design.md` and the "Approved exceptions" entry in `AGENTS.md` | Evidence that: session/admin/CSRF/owner checks reject adversarial requests; rename/reorder schemas remain closed and narrow; exact permutations are atomic and fail stale; `conversation_management_enabled` revokes both writes; the LLM has no organization tool; titles/order arrays/content never enter audit; the pinned Markdown parser/sanitizer corpus rejects active content with stable outcomes | UNSET | Not run |

### Local implementation evidence (not release approval)

On 2026-08-15, the implementation workspace passed 127 JavaScript tests; all
five Assistant Go race suites; both mandatory real Codex 0.144.4 MCP-boundary
tests; Zeitwerk; Tailwind CSS v4.3.1; `bundle-audit`; and focused release-gate
tests (27 runs and 1,056 assertions). The release workflow and live security
scripts now enumerate both direct runner images. The production-confidence
Brakeman gate passed with no warnings; its broader default scan reports one
pre-existing medium `permit!` warning in the intentionally schemaless
vulnerability document endpoint. The first full Rails run completed 1,361 runs
and 7,166 assertions with one documentation assertion failure; the assertion
was fixed and its focused suite passed, but PostgreSQL then stopped accepting
connections before a fresh full-suite run.

On 2026-08-19, the administrator-equivalent Hunter MCP implementation passed a
fresh full Rails run (1,413 runs and 7,609 assertions), all 127 JavaScript tests,
and all five Assistant Go suites under the race detector. Source verification
also confirmed exact parity for 70 reviewed tools across Rails, Hunter MCP,
Codex, and Claude; classified all 186 API operations (139 public and 47
Assistant-internal); passed Zeitwerk; passed the pinned Brakeman scanner with 79
checks, zero errors, and zero warnings; and passed `git diff --check`. These are
local source results only. The unavailable Docker runtime and unresolved
`dockergateway` hostname prevented deployed end-to-end acceptance evidence, so
the formal rows above remain `Not run` and production activation remains denied.

This environment has no Docker-compatible runtime, `gitleaks`, `govulncheck`,
image scanner, or SBOM toolchain, so it could not produce
candidate image digests, resolved Compose output, image/runtime inspection,
login persistence, live browser smoke, network denials, log canaries, or
rollback evidence. None of the formal rows above are satisfied by this local
record. Keep the explicit enable decision denied until a fixed candidate passes
the complete runbook and an independent Reviewer signs it.

## Runtime and operations review

- [ ] Activation is provider-key independent: `ASSISTANT_ENABLED` and the
      database administrator switch are the authoritative global revocation
      controls; missing subscription login produces a stable backend-specific
      turn failure and never enables an API-key fallback.
- [ ] The database kill switch is false and there are no active turn grants.
- [ ] Only the configured session administrator can access the browser surface.
- [ ] Active-path tokens (`ASSISTANT_CODEX_INGRESS_TOKEN`,
      `ASSISTANT_CLAUDE_INGRESS_TOKEN`, `ASSISTANT_GATEWAY_MCP_TOKEN`, and
      `ASSISTANT_MCP_HUNTER_TOKEN`) are non-empty and pairwise distinct. The
      intentional exception is that Compose maps `ASSISTANT_GATEWAY_MCP_TOKEN`
      into both runners' service-specific MCP bearer variables; it is not a
      provider credential.
- [ ] No service definition in the resolved Compose configuration mounts
      `./secrets`, references an `assistant_secrets` volume, or hands its
      whole `.env` to a service. No direct runner receives a provider API-key
      name, the other runner's ingress bearer, or the other login volume.
- [ ] `POST /chat` on both `assistant-codex` and `assistant-claude` rejects an
      unauthenticated/wrongly-authenticated request and a request whose Host is
      outside its exact allowlist before invoking a CLI.
- [ ] `runner`, `ansible-executor`, `web`, and `hunter-mcp` receive neither
      subscription login volume nor any direct provider credential.
- [ ] Production networks match the exact direct matrix. Each runner has only
      one Rails ingress network, its own internal Hunter MCP network, and its
      own provider-egress network. `hunter-mcp` has no provider egress;
      neither runner has a datastore, Control Center, Docker, host, or direct
      Hunter API route; no Assistant port is published.
- [ ] Active service-specific seccomp denial probes pass on the deployment
      kernel/runtime for `assistant-codex`, `assistant-claude`, and
      `hunter-mcp`; each retains read-only root, uid 1000, `cap_drop: ALL`,
      `no-new-privileges`, bounded tmpfs/resources/processes, and Docker's
      built-in `docker-default` AppArmor profile.
- [ ] The Codex image reports `codex-cli 0.144.4`; the exact eight built-ins,
      sole deferred `hunter` catalog, and immutable-workspace patch-denial
      real-binary tests ran rather than skipped and match the candidate.
- [ ] Codex authenticated only through `codex login --device-auth`; no
      `--with-api-key`, `--with-access-token`, `OPENAI_API_KEY`, or
      `CODEX_API_KEY` path exists. Claude authenticated only through its
      subscription login. Both login states survive service restart.
- [ ] Transcript/audit/backup retention and immediate-delete wording were
      reviewed against deployment and provider policy. Direct credentials live
      only in their dedicated named volumes; service bearers live only in the
      process environment sourced from the protected host `.env`.
- [ ] The credential-rotation and incident-response runbooks were exercised by
      the named operators; last rotation date (UTC): **UNSET**.
- [ ] Monitoring is metadata-only and alert ownership/escalation is recorded.
- [ ] Browser smoke proves one-click deduplication, both provider identities,
      new/resumed real turns, legacy read-only rejection, stable failures,
      history/code controls, and no console errors through port 5000.
- [ ] Unique prompt/reply/grant/login/tool canaries are absent from audit rows,
      service logs, and API error bodies. Audit inspection includes only the
      closed metadata fields; transcripts contain only expected message bodies.
- [ ] Rollback was exercised with kill switches off and no active grants. It
      restores a complete previously approved candidate (including dormant
      `legacy-gateway` services if required) without rewriting conversation or
      continuity bindings.
- [ ] No external deployment-control product is a runtime dependency.

## Findings and remediation

| ID | Severity | Finding | Remediation commit/image digest | Retest evidence | Status |
|---|---|---|---|---|---|
| ZSA-1 | Low (legacy rollback only) | A provider key with internal whitespace or control characters classifies as `valid` in the dormant legacy Rails preflight but is rejected by the legacy Go gateway's stricter reader, so a legacy turn ends as `provider_not_allowed`. Current direct chat never reads provider keys, never offers legacy profiles, and cannot reach this path. Reassess this accepted limitation if a rollback candidate activates `legacy-gateway`. | N/A — accepted legacy limitation, not remediated in current direct chat | Troubleshooting entries recorded in `.env.example` and `docs/runbooks/hunter-assistant-incident-response.md`; direct-provider regression evidence proves API-key-independent activation | Accepted |
| UNSET | UNSET | UNSET | UNSET | UNSET | Open |

Any Critical or High finding keeps the feature disabled. Accepted risk is not a
substitute for remediation at those severities. A changed image, dependency,
Compose definition, provider profile, secret mount, network, tool, context type,
write path, or execution path invalidates affected evidence and requires a new
review delta.

## Explicit enable decision

- Enable decision: **DENIED / NOT YET REVIEWED**
- Approved deployment/profile scope: **NONE**
- Reviewer name/signature record: **UNSET**
- Operator name/signature record: **UNSET**
- Decision timestamp (UTC): **UNSET**
- Staged rollout/rollback record: **UNSET**

Changing `ASSISTANT_ENABLED` is a separate operator action after approval. This
checklist never performs that action. If approval is absent, expired, or scoped
to different image digests or provider profiles, the only valid state is
disabled.
