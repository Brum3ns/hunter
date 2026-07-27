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

The two provider keys are the only credentials in the matrix above with a
host source file: they live outside Git and images in `secrets/`, mode `0600`
owned `1000:1000`, and reach `assistant-gateway` only through a read-only bind
mount of that directory at `/run/secrets`. The gateway-to-MCP token,
MCP-to-Hunter token, and the three RabbitMQ passwords have no host source file
at all — they are generated inside a container straight into the
`assistant_secrets` Docker volume, mode `0400`, mounted at
`/run/assistant/secrets` and read-only on every consumer except the two
one-shots that generate them. (A fourth, temporary RabbitMQ provisioner
password lives in the same volume; it is not operator-facing and is not
listed above.) The turn grant is a database-issued token, not a file. Processes
must not print any credential's contents, paths, digests, or request headers.

## Upgrading onto the bootstrap volume (one time)

The six machine credentials are generated at first boot into the shared
`assistant_secrets` volume by two one-shots, replacing the earlier file-backed
Compose secrets: `assistant-secrets-init` generates the five that need no
database (the four AMQP passwords and the gateway MCP token) and unblocks
`rabbitmq` without the broker inheriting a dependency on Rails; once `web`
reports healthy, `assistant-token-init` mints the sixth — the MCP-to-Hunter
service token — because minting it requires the migrated database. Docker
seeds a named volume from the image only while that volume is still empty, so
a host that ran an earlier build already has `assistant_secrets` owned
`root:root 0755`. The new image layer does not change it, both one-shots run
as uid 1000 and cannot write it, and every other service mounts the volume
read-only, so nothing repairs it in place. Because `rabbitmq` — and therefore
`web` — waits on `assistant-secrets-init`, the result is a stack-wide outage
rather than a degraded assistant.

Before the first `up` on the new images, remove the stale volume once:

```sh
docker compose down
docker volume rm <project>_assistant_secrets
```

Nothing is lost: every credential in it is regenerated on the next boot. The
broker's stored password hashes are rotated to match by
`assistant-rabbitmq-init`; set `ASSISTANT_RABBITMQ_REPROVISION=true` for that
one boot if the broker's data volume is being kept.

## Planned rotation

Set the database assistant setting false first and confirm new turns return
`assistant_disabled`; wait for or cancel in-flight turns and revoke all
remaining grants. Then follow the procedure for the credential being rotated.

### Provider key rotation

1. Replace the provider's key at the provider (revoke the old value there).
2. Overwrite `secrets/assistant_openai_api_key` or
   `secrets/assistant_anthropic_api_key` with the new value, keeping mode
   `0600` and owner `1000:1000`.
3. Recreate `assistant-gateway` only — it is the sole reader of either file.
   No other service needs to restart.
4. Confirm the old key is rejected at the provider and the new key completes
   a chat turn end to end.

### Machine credential rotation (RabbitMQ passwords, MCP tokens)

The five credentials `assistant-secrets-init` generates and the one
`assistant-token-init` mints are create-only: neither one-shot ever rewrites
an existing file, so rotation means deleting the target file from the
`assistant_secrets` volume and letting the corresponding one-shot regenerate
it, not editing anything in place.

1. Delete the specific credential file from the `assistant_secrets` volume
   (for example, exec into a container with the volume mounted read-write, or
   recreate the volume-owning one-shot after removing the file).
2. Restart `assistant-secrets-init` (for the four AMQP passwords or the
   gateway MCP token) or `assistant-token-init` (for the MCP-to-Hunter token),
   then every service that depends on it, in dependency order.
3. For a RabbitMQ password: set `ASSISTANT_RABBITMQ_REPROVISION=true`,
   force-recreate `rabbitmq` and `assistant-rabbitmq-init`, wait for the
   initializer to complete successfully, then remove the override before
   recreating the affected consumer(s) — this reprovisions the broker's own
   stored password hash to match. Leaving the override enabled would
   unnecessarily recreate the temporary broker administrator on a later
   restart.
4. For the MCP-to-Hunter token: `assistant-token-init` disables the previous
   `mcp_reader` service identity and mints a fresh one before writing the new
   token file, so the old raw token stops authenticating as soon as
   `hunter-mcp` picks up the new file.
5. Run `ops/assistant/check_secret_leaks.sh`. (The isolated RabbitMQ rotation
   drill was removed with the broker; there is no longer an AMQP credential to
   rotate.)
6. Confirm old service/queue/grant values all fail and new ones authenticate,
   then re-enable the database assistant setting. The deployment-wide
   `ASSISTANT_ENABLED` kill override remains an independent, separate control.

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
