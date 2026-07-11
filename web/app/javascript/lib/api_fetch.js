// Shared JSON fetch for Control Center Stimulus controllers. Sends the session
// cookie (credentials: same-origin) and, for writes, the X-CSRF-Token from the
// <meta name="csrf-token"> tag — the API's cookie auth path is CSRF-protected.
// Returns { ok, status, data }; data is null for empty bodies (e.g. 204).
export async function apiFetch(url, { method = "GET", body } = {}) {
  const headers = { Accept: "application/json" }
  if (body !== undefined) headers["Content-Type"] = "application/json"
  if (method !== "GET" && method !== "HEAD") {
    const token = document.querySelector('meta[name="csrf-token"]')?.content
    if (token) headers["X-CSRF-Token"] = token
  }
  const res = await fetch(url, {
    method,
    headers,
    credentials: "same-origin",
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  const text = await res.text()
  return { ok: res.ok, status: res.status, data: text ? JSON.parse(text) : null }
}
