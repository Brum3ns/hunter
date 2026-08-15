# Hunter

Hunter is a Rails 8 bug-bounty dashboard with separate departments for
programs, vulnerability management, Control Center automation, CVE tracking,
and an administrator-only draft-authoring Assistant.

The Rails application lives in `web/`; the development and production stacks
are defined by the root Compose files. See `AGENTS.md` for the current
architecture and repository conventions.

## Assistant security gate

The Assistant is disabled by default and is not enabled by building or
deploying these images. Its approved design and threat model are in
`docs/superpowers/specs/2026-07-25-hunter-assistant-security-design.md` and
`docs/security/hunter-assistant-threat-model.md`. The current direct-provider
delta uses isolated subscription-authenticated Codex and Claude Code services;
every Hunter read or effect, including future API-backed features, must pass
through the authenticated, per-turn-authorized Hunter MCP gateway. See
`docs/superpowers/specs/2026-08-13-assistant-direct-provider-selection-design.md`
and `docs/superpowers/specs/2026-08-15-assistant-codex-mcp-boundary-design.md`.

Generate narrowly named deployment credentials without printing their values:

```sh
ops/assistant/generate_secrets.sh dev
```

The active chat services start without the dormant `legacy-gateway` profile.
They use persistent, isolated login volumes and accept no provider API key:

```sh
docker compose run --rm --no-deps --entrypoint codex assistant-codex login --device-auth
docker compose run --rm --no-deps --entrypoint claude assistant-claude login
docker compose up -d web hunter-mcp assistant-codex assistant-claude
```

Do not use Codex's API-key or access-token login options. Follow
`docs/runbooks/assistant-codex-mcp-smoke-test.md` for version, login persistence,
exact tool-schema, immutable-workspace, browser, canary, and rollback evidence.

The production release gate consists of the full Rails, JavaScript, and Go test
suites plus:

```sh
ops/assistant/verify_compose_security.sh
ops/assistant/test_network_denials.sh
ops/assistant/check_secret_leaks.sh
```

The last two checks require a live hardened stack and the pinned scanner
toolchain. Exit status `77` means the required runtime/tool is unavailable; it
is not a pass. The exact Codex 0.144.4 built-in/Hunter MCP schema capture and
read-only `apply_patch` denial are also release gates. Production remains at
`ASSISTANT_ENABLED=false` until
`docs/security/hunter-assistant-production-checklist.md` is completed and
independently approved.
