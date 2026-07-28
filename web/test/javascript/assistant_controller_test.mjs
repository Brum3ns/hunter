import test from "node:test"
import assert from "node:assert/strict"
import { assistantApi } from "../../app/javascript/lib/assistant_api.js"

const ui = await import("../../app/javascript/lib/assistant_ui.js").catch(() => ({}))

class FakeElement {
  constructor(tagName) {
    this.tagName = tagName
    this.children = []
    this.attributes = {}
    this.dataset = {}
    this.hidden = false
    this.disabled = false
    this._textContent = ""
  }

  set textContent(value) { this._textContent = String(value); this.children = [] }
  get textContent() { return this._textContent + this.children.map((child) => child.textContent).join("") }
  set innerHTML(_value) { throw new Error("innerHTML must never be used") }
  append(...children) { this.children.push(...children) }
  appendChild(child) { this.children.push(child); return child }
  replaceChildren(...children) { this.children = children }
  setAttribute(name, value) { this.attributes[name] = String(value) }
  addEventListener(name, handler) { this[`on${name}`] = handler }

  querySelector(tagName) {
    for (const child of this.children) {
      if (child.tagName === tagName) return child
      const nested = child.querySelector?.(tagName)
      if (nested) return nested
    }
    return null
  }
}

const fakeDocument = { createElement: (tagName) => new FakeElement(tagName) }

function installBrowserDoubles() {
  const requests = []
  globalThis.document = {
    querySelector(selector) {
      return selector === 'meta[name="csrf-token"]' ? { content: "csrf-test" } : null
    },
  }
  globalThis.fetch = async (url, options) => {
    requests.push({ url, options })
    return { ok: true, status: 200, async text() { return "{}" } }
  }
  return requests
}

test("assistant lifecycle API uses scoped encoded routes and CSRF for mutations", async () => {
  const requests = installBrowserDoubles()

  await assistantApi.createTurn("7/unsafe", "Draft it", [{ type: "target", id: "a" }])
  await assistantApi.getTurn("8/unsafe")
  await assistantApi.cancelTurn("8/unsafe")
  await assistantApi.getDraft("9/unsafe")
  await assistantApi.confirmSave("9/unsafe", {
    name: "Probe",
    content_digest: "a".repeat(64),
    validation_version: "whiterabbit-v1",
    diff_digest: null,
    destination: null,
  })

  assert.equal(requests[0].url, "/api/v1/assistant/conversations/7%2Funsafe/turns")
  assert.equal(requests[0].options.method, "POST")
  assert.equal(requests[0].options.headers["X-CSRF-Token"], "csrf-test")
  assert.deepEqual(JSON.parse(requests[0].options.body), {
    message: "Draft it", contexts: [{ type: "target", id: "a" }],
  })
  assert.equal(requests[1].url, "/api/v1/assistant/turns/8%2Funsafe")
  assert.equal(requests[1].options.method, "GET")
  assert.equal(requests[2].url, "/api/v1/assistant/turns/8%2Funsafe/cancel")
  assert.equal(requests[2].options.method, "POST")
  assert.equal(requests[3].url, "/api/v1/assistant/drafts/9%2Funsafe")
  assert.equal(requests[4].url, "/api/v1/assistant/drafts/9%2Funsafe/confirmed_save")
  assert.equal(requests[4].options.method, "POST")
  assert.equal(requests[4].options.headers["X-CSRF-Token"], "csrf-test")
  assert.deepEqual(JSON.parse(requests[4].options.body), {
    confirmation: {
      name: "Probe",
      content_digest: "a".repeat(64),
      validation_version: "whiterabbit-v1",
      diff_digest: null,
      destination: null,
    },
  })
})

test("save confirmation text includes the complete reviewed effect and no execution claim", () => {
  assert.equal(typeof ui.saveConfirmationText, "function")
  const text = ui.saveConfirmationText({
    name: "Probe <script>",
    artifact_type: "whiterabbit_template",
    content: "complete content\n<script>alert(1)</script>",
    content_digest: "a".repeat(64),
    validation: { status: "valid", version: "whiterabbit-v1" },
    destination: { type: "whiterabbit_template", id: "12", lock_version: "3" },
    diff: "- old\n+ complete new",
  })

  assert.match(text, /Probe <script>/)
  assert.match(text, /whiterabbit_template #12 at version 3/)
  assert.match(text, /whiterabbit-v1/)
  assert.match(text, /- old\n\+ complete new/)
  assert.match(text, /does not run, send, schedule, or execute/i)
})

test("turn polling uses 750ms while open and backs off while closed until terminal", () => {
  assert.equal(typeof ui.pollingDelay, "function")
  assert.equal(ui.pollingDelay({ panelOpen: true, failureCount: 0 }), 750)
  assert.equal(ui.pollingDelay({ panelOpen: false, failureCount: 0 }), 3000)
  assert.equal(ui.pollingDelay({ panelOpen: false, failureCount: 3 }), 24000)
  assert.equal(ui.pollingDelay({ panelOpen: false, failureCount: 20 }), 30000)
  for (const status of ["completed", "failed", "canceled", "interrupted"]) {
    assert.equal(ui.terminalTurnStatus(status), true, status)
  }
  for (const status of ["created", "queued", "running", "unknown"]) {
    assert.equal(ui.terminalTurnStatus(status), false, status)
  }
})

test("latest-request tokens invalidate stale selections and in-flight polls", () => {
  assert.equal(typeof ui.LatestRequest, "function")
  const requests = new ui.LatestRequest()
  const first = requests.issue()
  const second = requests.issue()

  assert.equal(requests.current(first), false)
  assert.equal(requests.current(second), true)
  requests.invalidate()
  assert.equal(requests.current(second), false)
})

test("message rendering preserves adversarial markup as text and neutralizes control characters", () => {
  assert.equal(typeof ui.appendMessage, "function")
  const container = new FakeElement("section")
  const attack = '<script>alert("x")</script>\u001b[31m\u0000'

  ui.appendMessage(fakeDocument, container, { role: "assistant", body: attack })

  assert.equal(container.children.length, 1)
  assert.match(container.textContent, /<script>alert\("x"\)<\/script>/)
  assert.equal(container.textContent.includes("\u001b"), false)
  assert.equal(container.textContent.includes("\u0000"), false)
  assert.match(container.textContent, /Hunter assistant/)
})

test("selected context disclosure renders the sanitized preview as inert text", () => {
  assert.equal(typeof ui.appendContextDisclosure, "function")
  const container = new FakeElement("section")
  ui.appendContextDisclosure(fakeDocument, container, {
    type: "target",
    id: "target-1",
    label: '<img src=x onerror="steal()">\u001b[2J',
    preview: { data: { host: "<script>steal()</script>\u0000" } },
  }, () => {})

  assert.match(container.textContent, /<img src=x onerror="steal\(\)">/)
  assert.match(container.textContent, /<script>steal\(\)<\/script>/)
  assert.equal(container.textContent.includes("\u001b"), false)
  assert.equal(container.textContent.includes("\u0000"), false)
})

test("draft cards use only server validation state and text nodes for source and errors", () => {
  assert.equal(typeof ui.appendDraftCard, "function")
  const container = new FakeElement("section")
  let saves = 0
  const draft = {
    id: 4,
    artifact_type: "whiterabbit_template",
    name: '<img src=x onerror="steal()">',
    content: "<script>steal()</script>\u001b[2J",
    validation: {
      status: "valid", version: "whiterabbit-v1",
      codes: [], messages: ["<b>server says valid</b>\u0000"],
    },
    can_save: false,
    diff: "- <old>\n+ <new>",
  }

  ui.appendDraftCard(fakeDocument, container, draft, { onSave: () => { saves += 1 } })

  assert.match(container.textContent, /<img src=x onerror="steal\(\)">/)
  assert.match(container.textContent, /<script>steal\(\)<\/script>/)
  assert.match(container.textContent, /<b>server says valid<\/b>/)
  assert.match(container.textContent, /- <old>/)
  assert.equal(container.textContent.includes("\u001b"), false)
  const buttons = container.children[0].children.filter((child) => child.tagName === "button")
  assert.equal(buttons.some((button) => button.textContent === "Save draft"), false)
  assert.equal(saves, 0)
})

test("a current server-valid draft alone receives a save control", () => {
  const container = new FakeElement("section")
  let saves = 0
  ui.appendDraftCard(fakeDocument, container, {
    id: 5,
    artifact_type: "ansible_playbook",
    name: "Baseline",
    content: "---\n- hosts: all",
    validation: { status: "valid", version: "ansible-syntax-v1", codes: [], messages: [] },
    can_save: true,
    diff: null,
  }, { onSave: () => { saves += 1 } })

  const save = container.children[0].children.find((child) => child.textContent === "Save draft")
  assert(save)
  save.onclick()
  assert.equal(saves, 1)
})

test("a disabled assistant renders its reason as text", () => {
  assert.equal(typeof ui.renderDisabledNotice, "function")
  assert(Object.isFrozen(ui.DISABLED_COPY), "DISABLED_COPY must be a frozen map")

  const notice = new FakeElement("p")
  const composer = new FakeElement("textarea")

  ui.renderDisabledNotice(notice, composer, "no_provider_credentials")

  assert.equal(
    notice.textContent,
    "Assistant disabled: no provider credentials are installed."
  )
  assert.equal(composer.disabled, true)
})

test("an unknown reason falls back to a generic notice and never renders markup", () => {
  const notice = new FakeElement("p")
  const composer = new FakeElement("textarea")

  ui.renderDisabledNotice(notice, composer, "<img src=x onerror=alert(1)>")

  assert.equal(notice.querySelector("img"), null)
  assert.equal(notice.textContent, "Assistant disabled.")
})

test("selecting an existing conversation while disabled keeps the composer disabled", () => {
  assert.equal(typeof ui.applyComposerAvailability, "function")
  const notice = new FakeElement("p")
  const composer = new FakeElement("textarea")
  const send = new FakeElement("button")

  ui.renderDisabledNotice(notice, composer, "no_provider_credentials")
  // Rendering a conversation re-decides composer availability. A conversation that
  // predates the assistant being disabled must not hand back a typeable composer.
  ui.applyComposerAvailability(composer, send, false)

  assert.equal(composer.disabled, true)
  assert.equal(send.disabled, true)
  assert.equal(notice.textContent, "Assistant disabled: no provider credentials are installed.")

  // An absent flag is treated as disabled, so a stale or partial payload fails closed.
  ui.applyComposerAvailability(composer, send, undefined)
  assert.equal(composer.disabled, true)
  assert.equal(send.disabled, true)
})

test("selecting a conversation while enabled restores the composer", () => {
  const composer = new FakeElement("textarea")
  const send = new FakeElement("button")
  composer.disabled = true
  send.disabled = true

  ui.applyComposerAvailability(composer, send, true)

  assert.equal(composer.disabled, false)
  assert.equal(send.disabled, false)
})
