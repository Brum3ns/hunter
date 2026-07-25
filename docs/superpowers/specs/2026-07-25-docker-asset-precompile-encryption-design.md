# Docker Asset Precompile Encryption Design

## Problem

The production image runs `rails assets:precompile` while Rails is configured
for the production environment. Rails therefore executes the production Active
Record Encryption initializer, which correctly rejects missing encryption
settings. The Gitea build does not have those settings because the real keys are
provided later, when `docker-compose.prod.yaml` starts the container.

## Design

Keep the runtime validation unchanged and provide fixed, non-secret build-only
values for the three Active Record Encryption settings in the same shell-command
environment as `SECRET_KEY_BASE_DUMMY`. The values exist only while asset
precompilation runs; they are not declared with `ARG` or `ENV`, and the real
production keys remain runtime configuration.

This keeps the built image environment-independent, avoids exposing production
keys to BuildKit, and preserves fail-fast validation when the container starts.

## Verification

Validate the Dockerfile syntax and inspect the resulting diff locally. The
authoritative end-to-end verification is the Gitea BuildKit job because this
workspace does not provide a Docker-compatible builder or a Ruby runtime.
