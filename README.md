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
`docs/security/hunter-assistant-threat-model.md`.

Generate deployment credentials without printing their values and review the
credential instructions before starting the `assistant` profile:

```sh
ops/assistant/generate_secrets.sh dev
```

The production release gate consists of the full Rails, JavaScript, and Go test
suites plus:

```sh
ops/assistant/verify_compose_security.sh
ops/assistant/test_network_denials.sh
ops/assistant/check_secret_leaks.sh
ops/assistant/rotation_drill.sh
```

The last three checks require a live hardened stack and the pinned scanner
toolchain. Exit status `77` means the required runtime/tool is unavailable; it
is not a pass. Production remains at `ASSISTANT_ENABLED=false` until
`docs/security/hunter-assistant-production-checklist.md` is completed and
independently approved.
