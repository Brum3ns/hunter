# Hunter Assistant Credential Rotation

## Credential matrix

| Credential | Raw readers | Hunter persistence | Rotation impact |
|---|---|---|---|
| `ASSISTANT_ANTHROPIC_API_KEY` | Gateway only | None; profile stores `secret_ref` | Recreate `assistant-gateway` |
| `ASSISTANT_OPENAI_API_KEY` | Gateway only | None; profile stores `secret_ref` | Recreate `assistant-gateway` |
| `ASSISTANT_GATEWAY_MCP_TOKEN` | Gateway (presents) and `hunter-mcp` (checks) | None | Recreate `assistant-gateway` and `hunter-mcp` |
| `ASSISTANT_MCP_HUNTER_TOKEN` | `hunter-mcp` (presents to Hunter) | SHA-256 digest in `Assistant::ServiceIdentity` | Recreate `hunter-mcp`; applied to Postgres by `db:seed` |
| `ASSISTANT_GATEWAY_INGRESS_TOKEN` | `web` (presents) and `assistant-gateway` (checks) | None | Recreate `web` and `assistant-gateway` |
| `ASSISTANT_VALIDATOR_INGRESS_TOKEN` | `web` (presents) and `assistant-validator` (checks) | None | Recreate `web` and `assistant-validator` |
| Turn grant | Current queue/MCP request only | SHA-256 digest and limits | Revoke; never rotate/reuse |

All six credentials above are plain environment variables — set in `.env`
(or whatever env mechanism the deployment uses) and read directly by the
consuming process. There is no secrets volume, no mounted file, and no
bootstrap one-shot; nothing generates or writes these values but the
operator. The turn grant is a database-issued token, not an environment
variable. Processes must not print any credential's contents, paths,
digests, or request headers.

A missing or malformed value for `ASSISTANT_GATEWAY_MCP_TOKEN` or
`ASSISTANT_GATEWAY_INGRESS_TOKEN` makes `assistant-gateway` call
`log.Fatal` at startup and crash-loop. The same is true for
`ASSISTANT_VALIDATOR_INGRESS_TOKEN` on `assistant-validator`, and for
`ASSISTANT_GATEWAY_MCP_TOKEN` / `ASSISTANT_MCP_HUNTER_TOKEN` on `hunter-mcp`.
Whitespace-only or empty values are rejected the same as unset ones — this is
not a soft failure, so double-check the new value before recreating a
service. The two provider keys are the exception: an absent, empty, or
placeholder key just drops that provider out of the gateway's available
profiles, it does not crash the process.

## Rotation procedure

1. **Edit `.env`** (or the deployment's environment source) with the new
   value for the credential being rotated.
2. **Recreate the affected service(s)** per the matrix above so the new
   process picks up the new environment — a plain restart is not enough if
   the orchestrator caches the old environment; use `docker compose up -d
   --force-recreate <service>` (or the equivalent for the deployment).
3. **For `ASSISTANT_MCP_HUNTER_TOKEN` specifically**, rotation is applied on
   the Rails side by `db:seed`: it disables the previous `mcp_reader`
   `Assistant::ServiceIdentity` row and installs a fresh row with the new
   token's digest. Run `docker compose exec web bin/rails db:seed` (or the
   deployment's seed step) after setting the new value and before — or as
   part of — recreating `hunter-mcp`, so the old raw token stops
   authenticating as soon as `hunter-mcp` starts presenting the new one.
4. **Confirm** the old value is rejected (401/unauthorized, or the previous
   `mcp_reader` identity fails) and the new value works end to end (a chat
   turn completes, or a validation request completes).
5. Run `ops/assistant/check_secret_leaks.sh` to confirm the rotation left no
   value in logs, images, or the resolved Compose config.

### Provider key rotation

1. Replace the provider's key at the provider (revoke the old value there).
2. Set `ASSISTANT_OPENAI_API_KEY` or `ASSISTANT_ANTHROPIC_API_KEY` in `.env`
   to the new value.
3. Recreate `assistant-gateway` only — it is the sole reader of either
   variable. No other service needs to restart.
4. Confirm the old key is rejected at the provider and the new key completes
   a chat turn end to end.

### Machine credential rotation (MCP token, ingress tokens)

Follow the general rotation procedure above. Recreate every service listed
as a reader in the matrix, not just one side of a pair — for example,
rotating `ASSISTANT_GATEWAY_INGRESS_TOKEN` requires recreating both `web`
(which presents it) and `assistant-gateway` (which checks it); recreating
only one leaves the pair unable to authenticate each other.

## Planned rotation

Set the database assistant setting false first and confirm new turns return
`assistant_disabled`; wait for or cancel in-flight turns and revoke all
remaining grants. Then follow the procedure for the credential being rotated,
and re-enable the database assistant setting once old values are confirmed
rejected and new values are confirmed working. The deployment-wide
`ASSISTANT_ENABLED` kill override remains an independent, separate control.

## Emergency rotation

Follow the incident-response containment order. Revoke first and rotate
while disabled. A provider-key compromise does not justify rotating or
exposing the MCP token; rotate credentials independently according to their
affected trust boundary. A Docker-host compromise requires rotation of all
Hunter and deployment credentials, not only assistant credentials. Do not
enable body tracing while investigating — see
`docs/runbooks/hunter-assistant-incident-response.md`.

## Verification evidence

Record only credential names, generation/activation/revocation timestamps,
operator, affected service/image digest, old-value rejection result, new-value
health result, and approval. Never record raw values, hashes suitable for
offline comparison, secret paths, prompt bodies, or tool results.
