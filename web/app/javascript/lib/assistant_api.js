async function request(url, { method = "GET", body, signal } = {}) {
  const headers = { Accept: "application/json" }
  if (body !== undefined) headers["Content-Type"] = "application/json"
  if (method !== "GET" && method !== "HEAD") {
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
    if (csrfToken) headers["X-CSRF-Token"] = csrfToken
  }

  try {
    const response = await fetch(url, {
      method,
      headers,
      credentials: "same-origin",
      body: body === undefined ? undefined : JSON.stringify(body),
      signal,
    })
    const text = await response.text()
    let data = null
    try { data = text ? JSON.parse(text) : null } catch { data = null }
    return { ok: response.ok, status: response.status, data }
  } catch (error) {
    if (error?.name === "AbortError") {
      return { ok: false, status: 0, data: null, aborted: true }
    }
    return { ok: false, status: 0, data: null }
  }
}

export const assistantApi = Object.freeze({
  bootstrap({ signal } = {}) {
    return request("/api/v1/assistant/bootstrap", { signal })
  },

  listConversations({ signal } = {}) {
    return request("/api/v1/assistant/conversations", { signal })
  },

  getConversation(id, { signal } = {}) {
    return request(`/api/v1/assistant/conversations/${encodeURIComponent(id)}`, { signal })
  },

  createConversation(providerProfileId, { signal } = {}) {
    return request("/api/v1/assistant/conversations", {
      method: "POST",
      body: { provider_profile_id: providerProfileId },
      signal,
    })
  },

  renameConversation(id, title, { signal } = {}) {
    return request(`/api/v1/assistant/conversations/${encodeURIComponent(id)}`, {
      method: "PATCH",
      body: { title },
      signal,
    })
  },

  reorderConversations(ids, { signal } = {}) {
    return request("/api/v1/assistant/conversations/order", {
      method: "PATCH",
      body: { conversation_ids: ids },
      signal,
    })
  },

  deleteConversation(id, { signal } = {}) {
    return request(`/api/v1/assistant/conversations/${encodeURIComponent(id)}`, {
      method: "DELETE",
      signal,
    })
  },

  contextOptions(type, query, { signal } = {}) {
    const params = new URLSearchParams({ type, q: query || "" })
    return request(`/api/v1/assistant/context_options?${params}`, { signal })
  },

  previewContexts(references, { signal } = {}) {
    return request("/api/v1/assistant/context_previews", {
      method: "POST",
      body: { references },
      signal,
    })
  },

  createTurn(conversationId, message, contexts, { signal } = {}) {
    return request(`/api/v1/assistant/conversations/${encodeURIComponent(conversationId)}/turns`, {
      method: "POST",
      body: { message, contexts },
      signal,
    })
  },

  getTurn(id, { signal } = {}) {
    return request(`/api/v1/assistant/turns/${encodeURIComponent(id)}`, { signal })
  },

  cancelTurn(id, { signal } = {}) {
    return request(`/api/v1/assistant/turns/${encodeURIComponent(id)}/cancel`, {
      method: "POST",
      signal,
    })
  },

  getDraft(id, { signal } = {}) {
    return request(`/api/v1/assistant/drafts/${encodeURIComponent(id)}`, { signal })
  },

  confirmSave(id, confirmation, { signal } = {}) {
    return request(`/api/v1/assistant/drafts/${encodeURIComponent(id)}/confirmed_save`, {
      method: "POST",
      body: { confirmation },
      signal,
    })
  },
})
