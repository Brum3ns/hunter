import test from "node:test"
import assert from "node:assert/strict"
import { assistantApi } from "../../app/javascript/lib/assistant_api.js"

function installBrowserDoubles() {
  const requests = []
  globalThis.document = {
    querySelector(selector) {
      return selector === 'meta[name="csrf-token"]' ? { content: "csrf-test" } : null
    },
  }
  globalThis.fetch = async (url, options) => {
    requests.push({ url, options })
    return {
      ok: true,
      status: options.method === "DELETE" ? 204 : 200,
      async text() { return options.method === "DELETE" ? "" : '{"ok":true}' },
    }
  }
  return requests
}

test("assistantApi sends same-origin JSON with the CSRF token", async () => {
  const requests = installBrowserDoubles()

  await assistantApi.createConversation("codex")

  const request = requests[0]
  assert.equal(request.url, "/api/v1/assistant/conversations")
  assert.equal(request.options.headers["X-CSRF-Token"], "csrf-test")
  assert.equal(request.options.credentials, "same-origin")
  assert.equal(request.options.method, "POST")
  assert.deepEqual(JSON.parse(request.options.body), { backend: "codex" })
})

test("assistantApi reads bootstrap without a CSRF header and forwards abort signals", async () => {
  const requests = installBrowserDoubles()
  const controller = new AbortController()

  const response = await assistantApi.bootstrap({ signal: controller.signal })

  assert.deepEqual(response, { ok: true, status: 200, data: { ok: true } })
  assert.equal(requests[0].url, "/api/v1/assistant/bootstrap")
  assert.equal(requests[0].options.method, "GET")
  assert.equal(requests[0].options.headers["X-CSRF-Token"], undefined)
  assert.equal(requests[0].options.signal, controller.signal)
})

test("assistantApi deletes only the encoded conversation path", async () => {
  const requests = installBrowserDoubles()

  const response = await assistantApi.deleteConversation("7/unsafe")

  assert.equal(requests[0].url, "/api/v1/assistant/conversations/7%2Funsafe")
  assert.equal(requests[0].options.method, "DELETE")
  assert.equal(response.status, 204)
  assert.equal(response.data, null)
})

test("assistantApi reports an intentional abort without leaking an unhandled rejection", async () => {
  globalThis.document = { querySelector() { return null } }
  globalThis.fetch = async () => {
    const error = new Error("aborted")
    error.name = "AbortError"
    throw error
  }

  const response = await assistantApi.bootstrap({ signal: new AbortController().signal })

  assert.deepEqual(response, { ok: false, status: 0, data: null, aborted: true })
})
