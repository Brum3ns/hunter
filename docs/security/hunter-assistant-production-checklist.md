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
| Web / Assistant events and initializer | UNSET | UNSET | No |
| Assistant RabbitMQ | UNSET | UNSET | No |
| Assistant gateway | UNSET | UNSET | No |
| Hunter MCP | UNSET | UNSET | No |
| Assistant validator | UNSET | UNSET | No |
| Assistant egress | UNSET | UNSET | No |

## Verification artifacts

Store artifacts in the approved release-evidence system and record identifiers,
checksums, tool versions, execution times, and pass/fail status. Do not link to
mutable “latest” results.

| Gate | Required evidence | Artifact/checksum | Result |
|---|---|---|---|
| Rails, JavaScript, Go race suites | Complete logs | UNSET | Not run |
| MCP conformance and adversarial fixtures | Complete logs | UNSET | Not run |
| Resolved development/production Compose | Redacted configs | UNSET | Not run |
| Runtime hardening/AppArmor/seccomp | Verification output | UNSET | Not run |
| Network denial | DNS and direct-IP denial output | UNSET | Not run |
| Secret leakage | Git/history/config/log/layer/SBOM scan output | UNSET | Not run |
| Dependency audit | Brakeman, bundle-audit, govulncheck | UNSET | Not run |
| Image vulnerability scan | Critical/High fail-closed report | UNSET | Not run |
| CycloneDX SBOM | One per candidate image | UNSET | Not run |
| SPDX SBOM | One per candidate image | UNSET | Not run |
| Credential rotation drill | Old rejection/new health output | UNSET | Not run |

## Runtime and operations review

- [ ] `ASSISTANT_ENABLED=false` is present in the resolved production config.
- [ ] The database kill switch is false and there are no active turn grants.
- [ ] Only the configured session administrator can access the browser surface.
- [ ] Provider/service/RabbitMQ/grant credentials are distinct and file-mounted
      only according to the tested credential matrix.
- [ ] Secret source ownership/mode and effective read-only mounts were verified.
- [ ] RabbitMQ tracing is disabled and the temporary provisioner user is absent.
- [ ] Production networks match the tested matrix; no Assistant port, Docker
      socket, host mount, database path, executor path, or direct Internet path
      was added.
- [ ] AppArmor profiles are loaded and service-specific seccomp denial probes
      pass on the deployment kernel/runtime.
- [ ] Transcript/audit/backup retention and immediate-delete wording were
      reviewed against deployment policy.
- [ ] The credential-rotation and incident-response runbooks were exercised by
      the named operators; last rotation date (UTC): **UNSET**.
- [ ] Monitoring is metadata-only and alert ownership/escalation is recorded.
- [ ] No external deployment-control product is a runtime dependency.

## Findings and remediation

| ID | Severity | Finding | Remediation commit/image digest | Retest evidence | Status |
|---|---|---|---|---|---|
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
