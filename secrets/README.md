# Hunter Assistant secrets

Assistant credentials are file-mounted and deliberately absent from `.env`,
Git, images, Rails records, and Compose environment values.

The two provider API keys live directly in this directory. Prepare it with:

```sh
ops/assistant/prepare_secrets.sh
```

The command only creates `secrets/` at mode `0700`; it never creates the key
files themselves. `assistant-gateway` reads them through a read-only bind
mount of this directory at `/run/secrets`, so an absent file is a supported
disabled state rather than a boot failure — the chat reports why a provider
is unavailable.

The six machine-credential secrets (RabbitMQ, queue, and MCP tokens) still use
the `ASSISTANT_SECRET_DIR`-selected, file-backed Compose secret scheme
described below; only the two provider keys moved to this shared, bind-mounted
directory.

The hardened Compose services run as the fixed numeric identity `1000:1000`.
File-backed Compose secrets preserve host ownership on standalone Compose, so
the deployment secret files must also be owned by `1000:1000`. If the account
that generated them has a different identity, an administrator must apply
`chown 1000:1000` while retaining mode `0600`. Credential readers accept that
mode only when an attempted write is denied by the read-only secret mount.

When `ASSISTANT_SECRET_DIR` is unset, Compose points at checked-in inert files
under `secrets/disabled`. They exist only so the ordinary Hunter stack can boot
with the assistant profile disabled; their permissions and values are rejected
by every assistant credential reader. Never enable the feature or start the
assistant profile with that directory.

Provider credentials are supplied by the deployment operator. Copy the inert
examples into this directory, replace the placeholder with the real value
without printing it, and keep the file at mode `0600`:

```sh
cp secrets/examples/openai_primary.example secrets/assistant_openai_api_key
cp secrets/examples/anthropic_primary.example secrets/assistant_anthropic_api_key
chmod 0600 secrets/assistant_openai_api_key secrets/assistant_anthropic_api_key
```

The MCP-to-Hunter token must be minted by Rails so Hunter stores only its
digest. Run this once, capture the final line directly into the deployment's
`assistant_mcp_hunter_token` file, then clear the terminal scrollback/history as
appropriate for the operator environment:

```sh
cd web
bin/rails assistant:service_tokens:create NAME=hunter-mcp ROLE=mcp_reader
```

Never reuse a provider key, gateway-to-MCP token, MCP-to-Hunter token, RabbitMQ
password, ordinary API token, or Runner token for another role. Replacing a
secret requires recreating only the services named for it in the credential
matrix enforced by `web/test/config/assistant_compose_test.rb`.

Rotating one of the three Assistant RabbitMQ account passwords also requires a
single broker reprovisioning cycle while the feature is disabled. Set
`ASSISTANT_RABBITMQ_REPROVISION=true`, force-recreate `rabbitmq` and
`assistant-rabbitmq-init`, wait for the initializer to complete successfully,
then remove the override before recreating the three consumers. Leaving the
override enabled would unnecessarily recreate the temporary broker
administrator on a later broker restart; the Task 18 rotation drill automates
this bounded sequence.

Compose requests mode `0400` for each in-container secret mount. Standalone
Compose implementations may not honor `uid`, `gid`, or `mode` for file-backed
secrets; verify effective ownership and permissions with
`ops/assistant/verify_compose_security.sh` before enabling the feature. If the
runtime cannot provide a readable, read-only mount to the configured numeric
service user, keep `ASSISTANT_ENABLED=false` and use a supported secret backend
instead of widening file permissions.

On AppArmor-enabled deployment hosts, load the checked-in profiles before
creating the assistant containers:

```sh
sudo apparmor_parser -r ops/assistant/apparmor/hunter-assistant-gateway
sudo apparmor_parser -r ops/assistant/apparmor/hunter-mcp
sudo apparmor_parser -r ops/assistant/apparmor/hunter-assistant-validator
sudo apparmor_parser -r ops/assistant/apparmor/hunter-assistant-egress
```
