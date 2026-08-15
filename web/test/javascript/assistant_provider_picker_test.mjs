import test from "node:test"
import assert from "node:assert/strict"
import {
  chatBackendChoices,
  conversationIdentity,
} from "../../app/javascript/lib/assistant_provider_picker.js"

test("chat backend choices admit only enabled reviewed descriptors in closed order", () => {
  const choices = chatBackendChoices([
    {
      slug: "claude_code",
      brand: "anthropic",
      name: "server-controlled text",
      enabled: true,
      reviewed_at: "2026-08-13T00:00:00Z",
      retention_posture: "standard",
      model: "must not survive",
    },
    {
      slug: "codex",
      brand: "openai",
      enabled: true,
      reviewed_at: "2026-08-13T00:00:00Z",
      retention_posture: "standard",
      provider_profile_id: 77,
    },
    {
      slug: "future_backend",
      brand: "openai",
      enabled: true,
      reviewed_at: "2026-08-13T00:00:00Z",
    },
    {
      slug: "codex",
      brand: "anthropic",
      enabled: true,
      reviewed_at: "2026-08-13T00:00:00Z",
    },
    { slug: "codex", brand: "openai", enabled: false, reviewed_at: "2026-08-13T00:00:00Z" },
    { slug: "claude_code", brand: "anthropic", enabled: true, reviewed_at: null },
  ])

  assert.deepEqual(choices, [
    {
      backend: "codex",
      brand: "openai",
      label: "OpenAI",
      product: "Codex",
      retentionPosture: "standard",
    },
    {
      backend: "claude_code",
      brand: "anthropic",
      label: "Anthropic",
      product: "Claude Code",
      retentionPosture: "standard",
    },
  ])
  assert.equal(JSON.stringify(choices).includes("model"), false)
  assert.equal(JSON.stringify(choices).includes("provider_profile_id"), false)
})

test("conversation identity is immutable and unknown or legacy provenance becomes archive-only", () => {
  assert.deepEqual(
    conversationIdentity({ backend: "codex", brand: "openai", legacy: false }),
    {
      backend: "codex",
      brand: "openai",
      label: "OpenAI",
      product: "Codex",
      assetKey: "openai",
      legacy: false,
    },
  )
  assert.deepEqual(
    conversationIdentity({ backend: "claude_code", brand: "anthropic", legacy: false }),
    {
      backend: "claude_code",
      brand: "anthropic",
      label: "Anthropic",
      product: "Claude Code",
      assetKey: "anthropic",
      legacy: false,
    },
  )

  for (const conversation of [
    { backend: "codex", brand: "anthropic", legacy: false },
    { backend: "future", brand: "openai", legacy: false },
    { backend: "codex", brand: "openai", legacy: true },
  ]) {
    assert.deepEqual(conversationIdentity(conversation), {
      backend: null,
      brand: "archive",
      label: "Archived assistant",
      product: "Legacy conversation",
      assetKey: null,
      legacy: true,
    })
  }
})
