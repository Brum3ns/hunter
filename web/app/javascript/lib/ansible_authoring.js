export function acceptsYamlFilename(name) {
  return /\.(?:ya?ml)$/i.test(String(name || ""))
}

export function downloadFilename(name) {
  const withoutExtension = String(name || "").trim().replace(/\.ya?ml$/i, "")
  const safe = withoutExtension
    .replace(/[^A-Za-z0-9._-]+/g, "-")
    .replace(/^[-_.]+|[-_.]+$/g, "")
  return `${safe || "ansible-resource"}.yml`
}

export function fileValidationErrors(file, maxBytes) {
  if (!acceptsYamlFilename(file?.name)) return ["Choose a .yml or .yaml file."]
  if (file.size > maxBytes) return [`File exceeds the ${maxBytes}-byte limit.`]
  return []
}

export function nextDirtyState(current, event) {
  if (event === "edit") return true
  if (["saved", "loaded", "discarded"].includes(event)) return false
  return current
}

export function normalizeApiErrors(data, fallback = "Request failed.") {
  if (data?.details && typeof data.details === "object") {
    return Object.entries(data.details).flatMap(([field, messages]) =>
      (Array.isArray(messages) ? messages : [messages]).map((message) => `${field} ${message}`),
    )
  }
  if (Array.isArray(data?.detail)) return data.detail.map(String)
  if (data?.detail) return [String(data.detail)]
  if (Array.isArray(data?.errors)) return data.errors.map(String)
  return [fallback]
}
