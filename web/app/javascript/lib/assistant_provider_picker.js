const BACKEND_DEFINITIONS = Object.freeze([
  Object.freeze({
    backend: "codex",
    brand: "openai",
    label: "OpenAI",
    product: "Codex",
    assetKey: "openai",
  }),
  Object.freeze({
    backend: "claude_code",
    brand: "anthropic",
    label: "Anthropic",
    product: "Claude Code",
    assetKey: "anthropic",
  }),
])

const ARCHIVE_IDENTITY = Object.freeze({
  backend: null,
  brand: "archive",
  label: "Archived assistant",
  product: "Legacy conversation",
  assetKey: null,
  legacy: true,
})

function matchingDescriptor(descriptors, definition) {
  return descriptors.find((descriptor) =>
    descriptor?.slug === definition.backend &&
    descriptor?.brand === definition.brand &&
    descriptor?.enabled === true &&
    typeof descriptor?.reviewed_at === "string" &&
    descriptor.reviewed_at.length > 0
  )
}

export function chatBackendChoices(descriptors) {
  if (!Array.isArray(descriptors)) return []

  return Object.freeze(BACKEND_DEFINITIONS.flatMap((definition) => {
    const descriptor = matchingDescriptor(descriptors, definition)
    if (!descriptor) return []

    return [Object.freeze({
      backend: definition.backend,
      brand: definition.brand,
      label: definition.label,
      product: definition.product,
      retentionPosture: typeof descriptor.retention_posture === "string"
        ? descriptor.retention_posture
        : "not available",
    })]
  }))
}

export function conversationIdentity(conversation) {
  if (conversation?.legacy === true) return { ...ARCHIVE_IDENTITY }

  const definition = BACKEND_DEFINITIONS.find((candidate) =>
    conversation?.backend === candidate.backend && conversation?.brand === candidate.brand
  )
  if (!definition) return { ...ARCHIVE_IDENTITY }

  return {
    backend: definition.backend,
    brand: definition.brand,
    label: definition.label,
    product: definition.product,
    assetKey: definition.assetKey,
    legacy: false,
  }
}
