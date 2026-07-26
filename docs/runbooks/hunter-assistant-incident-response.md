# Hunter Assistant Incident Response

## Trigger conditions

Start this runbook for suspected provider-key or service-token disclosure,
unexpected assistant data access, unauthorized tool/resource IDs, unexplained
provider traffic, failed grant enforcement, malicious image/dependency
findings, Docker-host compromise, or any assistant-caused write/execution.

Treat Docker-host compromise as full-stack compromise. Treat a confirmed
assistant write or execution as a critical boundary failure even if no damage
is visible.

## Immediate containment

1. Disable the assistant through `Assistant::KillSwitch.disable!` or the
   administrator settings control. If Rails is unavailable, set
   `ASSISTANT_ENABLED=false` and stop the gateway, MCP, validator, event
   consumer, and egress services.
2. Confirm all active grants are revoked and the MCP reader identity is
   disabled. Do not re-enable either during investigation.
3. Block provider keys at OpenAI/Anthropic and deny assistant egress.
4. Preserve PostgreSQL metadata audits, RabbitMQ configuration metadata,
   image digests, deployment manifests, and host security logs. Do not enable
   body tracing or copy conversation/tool bodies into tickets.
5. Isolate affected containers and host. Do not enter a suspect container to
   inspect secrets before collecting host-level evidence.

## Scope assessment

Determine the first/last suspicious correlation ID, user, conversation, turn,
provider profile/model, tool, authorized resource reference, byte count,
validation result, and confirmed-save hash. Compare observed access with the
grant's exact resources and tool set. Confirm whether ordinary Hunter,
Control Center, runner, executor, database, target, or arbitrary Internet paths
were reached.

Audit records intentionally contain no prompts, responses, drafts, tool bodies,
raw tokens, secret paths, validator stderr, or process environments. Absence of
those bodies is expected and must not be worked around by weakening logging.

## Credential rotation order

Rotate in this order so no old credential regains authority:

1. Keep the global assistant gate disabled.
2. Revoke active turn grants and disable assistant service identities.
3. Revoke provider keys at the provider.
4. Replace the gateway-to-MCP token.
5. Mint a new digest-only MCP reader identity and replace MCP's raw token file.
6. Replace Rails, gateway, and validator RabbitMQ passwords independently;
   reprovision permissions and remove old users.
7. Replace provider key files and recreate only the affected services.
8. If the Docker host was compromised, rotate every Hunter credential,
   including database, MongoDB, RabbitMQ administrator, Rails secret/encryption,
   API, runner, executor, and deployment registry credentials.

Use
[`hunter-assistant-credential-rotation.md`](hunter-assistant-credential-rotation.md)
for the credential matrix and validation steps.

## Recovery

1. Patch the root cause and rebuild from reviewed, pinned sources.
2. Run Rails, JavaScript, Go, conformance, adversarial, network-denial,
   container-hardening, secret-leak, SBOM, and vulnerability gates.
3. Reconcile every confirmed save during the incident window against its
   administrator, destination, validation version, and content hashes.
4. Restore provider profiles only after their retention/security posture is
   reconfirmed.
5. Obtain independent review for a boundary failure or host compromise.
6. Enable fresh service identities first, then the database setting, then the
   infrastructure gate. Never reactivate old grants or credentials.
7. Monitor metadata-only audits and provider usage closely during staged
   re-enablement.

## Closure

Document timeline, blast radius, root cause, affected identifiers, credentials
rotated, artifacts reviewed, user/provider notifications, corrective controls,
verification evidence, and approvers. Store no secret or conversation body in
the incident record. Add a regression/adversarial test before closing.
