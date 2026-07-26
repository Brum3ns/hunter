# Hunter Assistant secrets

Assistant credentials are file-mounted and deliberately absent from `.env`,
Git, images, Rails records, and Compose environment values.

## Zero-step operator procedure

1. Create this directory if it does not already exist:

   ```sh
   ops/assistant/prepare_secrets.sh
   ```

   The script creates `secrets/` at mode `0700` and chowns it to `1000:1000`
   when it has permission to (printing a note when it does not); it never
   creates the key files themselves.

2. Put a provider key in `secrets/assistant_openai_api_key` and/or
   `secrets/assistant_anthropic_api_key`, mode `0600`, owned `1000:1000` (the
   fixed numeric identity every hardened Assistant container runs as). The
   `secrets/` directory itself must be owned `1000:1000` too — a key file with
   the right owner sitting inside a directory owned by someone else still
   blocks uid 1000 from traversing it:

   ```sh
   printf '%s' "$OPENAI_KEY" > secrets/assistant_openai_api_key
   chmod 0600 secrets/assistant_openai_api_key
   chown 1000:1000 secrets/assistant_openai_api_key
   chown 1000:1000 secrets
   ```

3. Run `docker compose up`. That is the whole procedure — no flag, profile,
   rake task, or admin UI step is required.

`assistant-gateway` reads both files through a read-only bind mount of this
directory at `/run/secrets`, so an absent file is a supported disabled state
rather than a boot failure. An absent or empty key file means that provider
stays disabled and the chat says so — absent and empty are indistinguishable
to the operator, and neither is ever a boot failure. Installing only one of
the two files is fully supported: the other provider simply stays disabled.

With zero keys installed, `assistant-gateway` idles and its `/healthz` probe
reports 503, so `docker compose ps` shows it permanently `unhealthy`. That is
expected, not a fault: nothing depends on the gateway's health, and it
resolves itself as soon as a valid key is installed and the service restarts.

The six machine credentials (RabbitMQ passwords and MCP tokens) are no longer
operator-supplied at all. `assistant-secrets-init` generates five of them on
first boot into the `assistant_secrets` Docker volume at
`/run/assistant/secrets` — it needs no database, so it runs before `rabbitmq`
and unblocks the broker without the broker inheriting a dependency on the
Rails app. `assistant-token-init` mints the sixth, the MCP-to-Hunter service
token, once `web` reports healthy (it needs a migrated database). There is no
manual rake task or raw-token paste step for either. Only the two provider
keys ever live in this directory.

## Upgrading from an earlier build (one time)

Docker seeds a named volume from the image only while the volume is still
empty, so a host that ran a build predating the `assistant_secrets` volume has
it owned `root:root` and `assistant-secrets-init` (uid 1000) cannot write it.
Since `rabbitmq` — and therefore `web` — waits on that one-shot, the whole
stack stays down, not just the assistant. Remove the stale volume once before
the first `up` on the new images:

```sh
docker compose down
docker volume rm <project>_assistant_secrets
```

Nothing is lost: every credential in it is regenerated on the next boot. See
`docs/runbooks/hunter-assistant-credential-rotation.md` for the broker-side
detail.

## Troubleshooting

If a provider shows as available in the chat but every turn against it fails
with `provider_not_allowed`, check its key file for embedded spaces, tabs, or
control characters in the middle of the value. Rails' credential preflight
classifies a key with internal whitespace as `valid` — it only rejects
surrounding whitespace — while the gateway's own reader rejects any embedded
whitespace or control character outright and drops that provider rather than
exiting. Nothing crash-loops, but the mismatch means the chat still offers a
provider the gateway has silently refused to load; the only visible trace is
a slug-only line in the gateway's log. Replace the key file with a clean value
(no leading/trailing/embedded whitespace) and restart `assistant-gateway`.

The hardened Compose services run as the fixed numeric identity `1000:1000`.
The provider key files must therefore also be owned by `1000:1000`. If the
account that created them has a different identity, an administrator must apply
`chown 1000:1000` while retaining mode `0600`. Credential readers accept that
mode only when an attempted write is denied by the read-only secret mount.

Never reuse a provider key, gateway-to-MCP token, MCP-to-Hunter token, RabbitMQ
password, ordinary API token, or Runner token for another role. Replacing a
secret requires recreating only the services named for it in the credential
matrix in `docs/runbooks/hunter-assistant-credential-rotation.md`; the
per-service mount and network contract that matrix depends on is pinned by
`web/test/config/assistant_compose_test.rb`.

Rotating one of the three Assistant RabbitMQ account passwords also requires a
single broker reprovisioning cycle while the feature is disabled. Set
`ASSISTANT_RABBITMQ_REPROVISION=true`, force-recreate `rabbitmq` and
`assistant-rabbitmq-init`, wait for the initializer to complete successfully,
then remove the override before recreating the three consumers. Leaving the
override enabled would unnecessarily recreate the temporary broker
administrator on a later broker restart; `ops/assistant/rotation_drill.sh`
automates this bounded sequence. See
`docs/runbooks/hunter-assistant-credential-rotation.md` for the full rotation
procedure for both the provider keys and the bootstrap-generated machine
credentials.

Neither provider key is a Compose file-backed secret — both reach the gateway
through the read-only bind mount of this directory described above, so their
host-side mode and owner (`0600`, `1000:1000`) are what the gateway actually
sees; there is no separate in-container secret mode for Compose to enforce.
`ops/assistant/verify_compose_security.sh` checks the resolved development and
production Compose configuration and the loaded AppArmor profiles, not secret
file mode directly — the gateway's own `safeSecretMode` check is what rejects
a key file with an unaccepted mode at read time. If a deployment's Compose
implementation cannot provide a genuinely read-only bind mount to the
configured numeric service user, force every profile off with
`ASSISTANT_ENABLED=false` and use a supported secret backend instead of
widening file permissions.

On AppArmor-enabled deployment hosts, load the checked-in profiles before
creating the assistant containers:

```sh
sudo apparmor_parser -r ops/assistant/apparmor/hunter-assistant-gateway
sudo apparmor_parser -r ops/assistant/apparmor/hunter-mcp
sudo apparmor_parser -r ops/assistant/apparmor/hunter-assistant-validator
sudo apparmor_parser -r ops/assistant/apparmor/hunter-assistant-egress
```
