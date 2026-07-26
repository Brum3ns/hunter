# Hunter Assistant Credential Rotation

## Credential matrix

| Credential | Raw readers | Hunter persistence | Rotation impact |
|---|---|---|---|
| OpenAI key | Gateway only | None; profile stores `secret_ref` | Recreate gateway |
| Anthropic key | Gateway only | None; profile stores `secret_ref` | Recreate gateway |
| Gateway-to-MCP token | Gateway and MCP | None | Recreate gateway and MCP |
| MCP-to-Hunter token | MCP only | SHA-256 digest in service identity | Mint identity; recreate MCP |
| Rails assistant RabbitMQ password | Rails publisher/event consumer and one-shot provisioner | RabbitMQ password hash | Recreate Rails assistant processes |
| Gateway RabbitMQ password | Gateway and one-shot provisioner | RabbitMQ password hash | Recreate gateway |
| Validator RabbitMQ password | Validator and one-shot provisioner | RabbitMQ password hash | Recreate validator |
| Turn grant | Current queue/MCP request only | SHA-256 digest and limits | Revoke; never rotate/reuse |

Secret source files live outside Git and images. Compose mounts each only into
the listed service under `/run/secrets`. Host source files are mode 0600.
Processes must not print their contents, paths, digests, or request headers.

## Planned rotation

1. Set the database assistant setting false and confirm new turns return
   `assistant_disabled`.
2. Wait for or cancel in-flight turns; revoke all remaining grants.
3. Generate replacement values with `ops/assistant/generate_secrets.sh`.
4. For MCP-to-Hunter, run the service-token rake task. Store the raw value once
   in MCP's secret file; verify only its digest is present in PostgreSQL.
5. Reprovision RabbitMQ users with distinct passwords and the exact assistant
   vhost permission regexes. Delete old users after new consumers authenticate.
6. Replace provider keys at the provider and update only the matching source
   files.
7. Recreate affected services; never restart unrelated services merely to
   distribute a secret they do not consume.
8. Run `ops/assistant/rotation_drill.sh` and
   `ops/assistant/check_secret_leaks.sh`.
9. Confirm old provider, service, queue, and grant values all fail.
10. Re-enable reviewed service identities, then the database setting. The
    deployment-wide `ASSISTANT_ENABLED` gate remains an independent control.

## Emergency rotation

Follow the incident-response containment order. Revoke first and rotate while
disabled. A provider-key compromise does not justify rotating or exposing the
MCP token; rotate credentials independently according to their affected trust
boundary. A Docker-host compromise requires rotation of all Hunter and
deployment credentials, not only assistant credentials.

## Verification evidence

Record only credential names, generation/activation/revocation timestamps,
operator, affected service/image digest, old-value rejection result, new-value
health result, and approval. Never record raw values, hashes suitable for
offline comparison, secret paths, prompt bodies, or tool results.
