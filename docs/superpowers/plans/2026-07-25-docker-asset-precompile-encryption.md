# Docker Asset Precompile Encryption Implementation Plan

> **For agentic workers:** Execute this plan inline; project instructions prohibit delegation unless the user explicitly requests it.

**Goal:** Allow the production Docker image to precompile assets without making real Active Record Encryption secrets available during the image build.

**Architecture:** Scope fixed non-secret encryption placeholders to the existing `assets:precompile` process. Keep real encryption keys in runtime compose configuration and retain the production initializer's fail-fast behavior.

**Tech Stack:** Dockerfile, Rails 8.1, Active Record Encryption, Gitea Actions/BuildKit

## Global Constraints

- Do not pass real encryption secrets into the image build.
- Do not persist build-only placeholders with Docker `ARG` or `ENV` instructions.
- Do not weaken production runtime validation.
- Do not modify, stage, or commit unrelated worktree changes.

---

### Task 1: Scope build-only encryption configuration to asset compilation

**Files:**
- Modify: `Dockerfile:51`

**Interfaces:**
- Consumes: the production `assets:precompile` command executed by BuildKit.
- Produces: a production image whose asset compilation can initialize Active Record Encryption without retaining build-only values.

- [x] Confirm the existing Gitea failure is caused by the three absent Active Record Encryption variables.
- [x] Add these fixed values as command-scoped environment assignments alongside `SECRET_KEY_BASE_DUMMY=1`:

  ```dockerfile
  ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=build-only-primary-key \
  ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=build-only-deterministic-key \
  ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=build-only-key-derivation-salt \
  ```
- [x] Check the Dockerfile with an available parser or shell syntax validation.
- [x] Inspect the final diff and confirm the runtime compose configuration and initializer are unchanged.
- [ ] Re-run `.gitea/workflows/build.yml` in Gitea for authoritative BuildKit verification.
