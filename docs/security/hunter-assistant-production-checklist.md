# Hunter Assistant production security checklist

This is a release evidence record, not an enable switch. Keep
`ASSISTANT_ENABLED=false` until every required field is complete, every attached
artifact corresponds to the exact candidate image digest, and the independent
Reviewer records an explicit enable decision. Never place a raw credential,
credential digest, prompt, response, selected-record body, draft body, or tool
result in this document or its attachments.

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

Complete one row for every profile that may be enabled. Provider retention,
training use, residency, abuse-monitoring access, and contractual eligibility
must be reviewed for the intended Hunter data classification. An unapproved
profile remains disabled and absent from administrator choices.

| Profile | Provider/model | Retention posture/evidence | Training use | Residency | Approver/date | Approved |
|---|---|---|---|---|---|---|
| UNSET | UNSET | UNSET | UNSET | UNSET | UNSET | No |

## Immutable image inventory

Record registry references by immutable `sha256:` digest. Tags alone are not
acceptable. The digest must match the image used for tests, SBOM generation,
scanning, and deployment.

| Component | Registry reference with digest | Build provenance | Signature/attestation verified |
|---|---|---|---|
| Web | UNSET | UNSET | No |
| Assistant gateway | UNSET | UNSET | No |
| Hunter MCP | UNSET | UNSET | No |
| Assistant validator | UNSET | UNSET | No |

## Verification artifacts

Store artifacts in the approved release-evidence system and record identifiers,
checksums, tool versions, execution times, and pass/fail status. Do not link to
mutable “latest” results.

| Gate | Required evidence | Artifact/checksum | Result |
|---|---|---|---|
| Rails, JavaScript, Go race suites | Complete logs | UNSET | Not run |
| MCP conformance and adversarial fixtures | Complete logs | UNSET | Not run |
| Resolved development/production Compose | Redacted configs | UNSET | Not run |
| Runtime hardening/seccomp (Docker default AppArmor) | Verification output | UNSET | Not run |
| Network denial | DNS and direct-IP denial output | UNSET | Not run |
| Secret leakage | Git/history/config/log/layer/SBOM scan output | UNSET | Not run |
| Dependency audit | Brakeman, bundle-audit, govulncheck | UNSET | Not run |
| Image vulnerability scan | Critical/High fail-closed report | UNSET | Not run |
| CycloneDX SBOM | One per candidate image | UNSET | Not run |
| SPDX SBOM | One per candidate image | UNSET | Not run |
| Credential rotation drill | Old rejection/new health output | UNSET | Not run |
| Live `docker compose up` acceptance run (no keys, empty keys, one real key, `docker compose config` secret review) | Operator-reported output for all four cases; `docker compose config` now inlines live environment-variable secret values rather than file paths, so its output must be captured only in redacted form for this record | UNSET | Not run |
| Approval-free create (Whiterabbit templates + Ansible playbooks) — see `docs/superpowers/specs/2026-07-30-assistant-approval-free-create-design.md` and the "Approved exceptions" entry in `AGENTS.md`'s Assistant capability change rule | Evidence that: the fail-closed validators (`AnsibleStatic`, `Whiterabbit`/`TemplateValidator`) reject every disallowed-module/command and secret-embedding fixture with no row persisted; the create endpoints are create-only (no edit/delete/run path exists); `control_center_templates_write`/`control_center_ansible_write` are non-wildcard and independently revocable via `Assistant::Setting#control_center_write_enabled`; created rows are attributed to the human turn user and metadata-only audited | UNSET | Not run |

## Runtime and operations review

- [ ] Activation is derived, not flag-gated: confirm only the intended
      provider environment variable(s) (`ASSISTANT_ANTHROPIC_API_KEY`,
      `ASSISTANT_OPENAI_API_KEY`) are set to a valid, non-placeholder value for
      the enabled profile(s) — an absent, empty, or placeholder value disables
      that provider; this is not itself a finding — and confirm the runtime
      kill switch (`ASSISTANT_ENABLED=false`, or the database admin
      off-switch) is available and tested to force every profile off
      regardless of key presence.
- [ ] The database kill switch is false and there are no active turn grants.
- [ ] Only the configured session administrator can access the browser surface.
- [ ] The four assistant ingress/service tokens
      (`ASSISTANT_GATEWAY_INGRESS_TOKEN`, `ASSISTANT_VALIDATOR_INGRESS_TOKEN`,
      `ASSISTANT_GATEWAY_MCP_TOKEN`, `ASSISTANT_MCP_HUNTER_TOKEN`) are set and
      pairwise distinct from each other and from both provider keys, per the
      tested credential matrix.
- [ ] No service definition in the resolved Compose configuration mounts
      `./secrets`, references an `assistant_secrets` volume, or hands its
      whole `.env` to a service via `env_file` that should not receive
      provider keys.
- [ ] `POST /turns` on `assistant-gateway` and `POST /validations` on
      `assistant-validator` each reject an unauthenticated or
      wrongly-authenticated request, and reject a request whose Host or Origin
      is not on the configured allowlist.
- [ ] `runner` and `ansible-executor` do not receive
      `ASSISTANT_ANTHROPIC_API_KEY` or `ASSISTANT_OPENAI_API_KEY` in the
      resolved Compose configuration.
- [ ] Production networks match the tested matrix; no Assistant port, Docker
      socket, host mount, database path, or executor path was added, and no
      assistant service other than `assistant-gateway` has an outbound
      Internet route. `assistant-gateway`'s own outbound reach is now
      unrestricted — the squid egress allowlist was removed — which is a
      recorded accepted risk, not a gap to close here; see
      `docs/superpowers/specs/2026-07-27-assistant-infra-simplification-delta.md`.
- [ ] Service-specific seccomp denial probes pass on the deployment
      kernel/runtime for all three assistant services (`assistant-gateway`,
      `hunter-mcp`, `assistant-validator`), and each still declares its
      `seccomp=` profile in the resolved Compose configuration. The three
      services run under Docker's built-in `docker-default` AppArmor profile;
      the custom profiles under `ops/assistant/apparmor/` are shipped but not
      loaded or referenced by Compose (removed 2026-07-26 — see
      `docs/superpowers/specs/2026-07-26-hunter-assistant-zero-step-activation-delta.md`),
      which is the accepted baseline, not a gap to close here.
- [ ] Transcript/audit/backup retention and immediate-delete wording were
      reviewed against deployment policy. There is no `assistant_secrets`
      Docker volume any more — secrets live only in the process environment,
      sourced from the host's `.env` file — so review the host's `.env`
      handling and backup process under the deployment's normal file-retention
      policy instead.
- [ ] The credential-rotation and incident-response runbooks were exercised by
      the named operators; last rotation date (UTC): **UNSET**.
- [ ] Monitoring is metadata-only and alert ownership/escalation is recorded.
- [ ] No external deployment-control product is a runtime dependency.

## Findings and remediation

| ID | Severity | Finding | Remediation commit/image digest | Retest evidence | Status |
|---|---|---|---|---|---|
| ZSA-1 | Low | A provider key with internal whitespace or control characters classifies as `valid` in Rails' credential preflight but is rejected by the Go gateway's stricter reader. The gateway drops that provider and logs a slug-only line rather than exiting, so nothing crash-loops, but the chat still offers the provider and its turns terminate as `provider_not_allowed` with the actual cause visible only in the gateway log. Closing this fully would need a ninth reason code (`malformed`) threaded through Rails' classifier, the client copy map, and the Go classifier; judged disproportionate given trailing whitespace is already trimmed and only embedded whitespace triggers it. | N/A — accepted known limitation, not remediated in code | Troubleshooting entries recorded in `.env.example` and `docs/runbooks/hunter-assistant-incident-response.md` | Accepted |
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
