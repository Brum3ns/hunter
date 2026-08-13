import test from "node:test"
import assert from "node:assert/strict"
import { register } from "node:module"
import { JSDOM } from "jsdom"
import { assistantApi } from "../../app/javascript/lib/assistant_api.js"

const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  url: "https://hunter.test/",
})
globalThis.window = dom.window
globalThis.document = dom.window.document

register("./support/assistant_controller_loader.mjs", import.meta.url)
const ui = await import("../../app/javascript/lib/assistant_ui.js").catch(() => ({}))

class FakeElement {
  constructor(tagName) {
    this.tagName = tagName
    this.children = []
    this.attributes = {}
    this.dataset = {}
    this.hidden = false
    this.disabled = false
    this.className = ""
    this.draggable = false
    this._textContent = ""
  }

  set textContent(value) { this._textContent = String(value); this.children = [] }
  get textContent() { return this._textContent + this.children.map((child) => child.textContent).join("") }
  set innerHTML(_value) { throw new Error("innerHTML must never be used") }
  append(...children) { this.children.push(...children) }
  appendChild(child) { this.children.push(child); return child }
  replaceChildren(...children) { this.children = children }
  setAttribute(name, value) { this.attributes[name] = String(value) }
  getAttribute(name) { return this.attributes[name] }
  removeAttribute(name) { delete this.attributes[name] }
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

class FakeTextNode {
  constructor(value) {
    this.tagName = "#text"
    this.textContent = String(value)
  }
}

const fakeDocument = {
  createElement: (tagName) => new FakeElement(tagName),
  createTextNode: (value) => new FakeTextNode(value),
}

function findElements(root, predicate) {
  const matches = []
  for (const child of root.children || []) {
    if (predicate(child)) matches.push(child)
    matches.push(...findElements(child, predicate))
  }
  return matches
}

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

test("conversation organization API uses dedicated encoded PATCH routes and exact bodies", async () => {
  const requests = installBrowserDoubles()

  await assistantApi.renameConversation("7/unsafe", "Renamed")
  await assistantApi.reorderConversations([9, 7])

  assert.equal(requests[0].url, "/api/v1/assistant/conversations/7%2Funsafe")
  assert.equal(requests[0].options.method, "PATCH")
  assert.equal(requests[0].options.headers["X-CSRF-Token"], "csrf-test")
  assert.deepEqual(JSON.parse(requests[0].options.body), { title: "Renamed" })
  assert.equal(requests[1].url, "/api/v1/assistant/conversations/order")
  assert.equal(requests[1].options.method, "PATCH")
  assert.equal(requests[1].options.headers["X-CSRF-Token"], "csrf-test")
  assert.deepEqual(JSON.parse(requests[1].options.body), { conversation_ids: [9, 7] })
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

test("composer Enter submits while Shift+Enter and composition keep editing", () => {
  assert.equal(
    ui.composerSubmitIntent({ key: "Enter", shiftKey: false, isComposing: false }),
    true,
  )
  assert.equal(
    ui.composerSubmitIntent({ key: "Enter", shiftKey: true, isComposing: false }),
    false,
  )
  assert.equal(
    ui.composerSubmitIntent({ key: "Enter", shiftKey: false, isComposing: true }),
    false,
  )
  assert.equal(
    ui.composerSubmitIntent({ key: "Escape", shiftKey: false, isComposing: false }),
    false,
  )
  for (const modifier of ["altKey", "ctrlKey", "metaKey"]) {
    assert.equal(
      ui.composerSubmitIntent({
        key: "Enter", shiftKey: false, isComposing: false, [modifier]: true,
      }),
      false,
      modifier,
    )
  }
})

test("conversation list renders an inert empty state and marks only the current chat", () => {
  assert.equal(typeof ui.renderConversationList, "function")
  const empty = new FakeElement("div")
  ui.renderConversationList(fakeDocument, empty, [], {})
  assert.match(empty.textContent, /No conversations yet/i)

  const list = new FakeElement("div")
  ui.renderConversationList(fakeDocument, list, [
    { id: 7, title: '<script>Current</script>' },
    { id: 8, title: "Older" },
  ], { currentId: 7, onSelect() {} })

  assert.equal(list.children.length, 2)
  const currentRow = list.children[0]
  const currentTitle = currentRow.children[0]
  assert.equal(currentTitle.textContent, "<script>Current</script>")
  assert.equal(list.children[0].querySelector("script"), null)
  assert.equal(currentTitle.attributes["aria-current"], "true")
  assert.match(currentRow.className, /assistant-conversation-active/)
  assert.equal(list.children[1].children[0].attributes["aria-current"], undefined)
})

test("conversation rows expose pointer keyboard menu and drag callbacks without parsing titles", () => {
  const events = []
  const list = new FakeElement("div")
  ui.renderConversationList(fakeDocument, list, [
    { id: "7/unsafe", title: '<img src=x onerror="steal()">' },
  ], {
    onSelect: (conversation) => events.push(["select", conversation.id]),
    onContextMenu: (conversation) => events.push(["context", conversation.id]),
    onMenu: (conversation) => events.push(["menu", conversation.id]),
    onDragStart: (conversation) => events.push(["dragstart", conversation.id]),
    onDragOver: (conversation) => events.push(["dragover", conversation.id]),
    onDrop: (conversation) => events.push(["drop", conversation.id]),
    onDragEnd: (conversation) => events.push(["dragend", conversation.id]),
  })

  const row = list.children[0]
  const title = row.children[0]
  const menu = row.children[1]
  assert.equal(row.draggable, true)
  assert.equal(title.dataset.conversationId, "7/unsafe")
  assert.equal(title.textContent, '<img src=x onerror="steal()">')
  assert.equal(title.querySelector("img"), null)
  assert.equal(menu.attributes["aria-haspopup"], "menu")
  assert.match(menu.attributes["aria-label"], /Actions for/)

  let prevented = 0
  title.onclick({})
  title.oncontextmenu({ preventDefault() { prevented += 1 } })
  title.onkeydown({ key: "F10", shiftKey: true, preventDefault() { prevented += 1 } })
  title.onkeydown({ key: "ContextMenu", shiftKey: false, preventDefault() { prevented += 1 } })
  menu.onclick({})
  row.ondragstart({})
  row.ondragover({})
  row.ondrop({})
  row.ondragend({})

  assert.equal(prevented, 3)
  assert.deepEqual(events, [
    ["select", "7/unsafe"],
    ["context", "7/unsafe"],
    ["menu", "7/unsafe"],
    ["menu", "7/unsafe"],
    ["menu", "7/unsafe"],
    ["dragstart", "7/unsafe"],
    ["dragover", "7/unsafe"],
    ["drop", "7/unsafe"],
    ["dragend", "7/unsafe"],
  ])
})

test("messages render safe Markdown cards with profile bubbles and original-body copy", () => {
  assert.equal(typeof ui.appendMessage, "function")
  const container = dom.window.document.createElement("section")
  const attack = '<script>alert("x")</script>\u001b[31m\u0000'
  const copied = []

  ui.appendMessage(
    dom.window.document,
    container,
    { role: "assistant", body: attack },
    { onCopy: (message) => copied.push(message.body) },
  )
  ui.appendMessage(
    dom.window.document,
    container,
    { role: "user", body: "**my question**" },
    { onCopy: (message) => copied.push(message.body) },
  )

  assert.equal(container.children.length, 2)
  assert.match(container.textContent, /<script>alert\("x"\)<\/script>/)
  assert.equal(container.textContent.includes("\u001b"), false)
  assert.equal(container.textContent.includes("\u0000"), false)
  assert.match(container.textContent, /Hunter assistant/)
  const assistantRow = container.children[0]
  const userRow = container.children[1]
  assert.equal(assistantRow.children[0].dataset.avatarRole, "assistant")
  assert.equal(assistantRow.children[1].tagName, "ARTICLE")
  assert.equal(userRow.children[0].tagName, "ARTICLE")
  assert.equal(userRow.children[1].dataset.avatarRole, "user")
  assert.equal(assistantRow.querySelectorAll(".assistant-markdown").length, 1)

  const copyButtons = [...container.querySelectorAll("button")]
    .filter((element) => element.textContent === "Copy")
  assert.equal(copyButtons.length, 2)
  copyButtons[0].click()
  copyButtons[1].click()
  assert.deepEqual(copied, [attack, "**my question**"])
})

test("fenced message code renders one compact toolbar and copies the complete source", () => {
  const source = Array.from(
    { length: 13 },
    (_, index) => index === 0 ? 'puts "<tag>"' : `puts ${index}`,
  ).join("\n")
  const container = dom.window.document.createElement("section")
  const copied = []

  ui.appendMessage(
    dom.window.document,
    container,
    { role: "assistant", body: `Use \`inline\`\n\n\`\`\`ruby\n${source}\n\`\`\`` },
    { onCopyCode: (text) => copied.push(text) },
  )

  const block = container.querySelector(".assistant-code-block")
  assert.equal(container.querySelectorAll(".assistant-code-toolbar").length, 1)
  assert.equal(block.dataset.compact, "true")
  assert.equal(container.querySelector("p code").closest(".assistant-code-block"), null)
  block.querySelector('[data-code-action="copy"]').click()
  assert.equal(copied[0], `${source}\n`)
})

test("conversation deletion confirmation names the effect without changing title text", () => {
  assert.equal(
    ui.conversationDeletionText({ title: '<script>Quarterly</script>' }),
    "Delete “<script>Quarterly</script>”?\n\n" +
      "Hunter will permanently delete this local conversation and its messages. " +
      "Provider or backup copies may remain under their retention policies.",
  )
})

test("message log scrolling follows the newest rendered content", () => {
  assert.equal(typeof ui.scrollMessageLog, "function")
  const container = new FakeElement("section")
  container.scrollTop = 0
  container.scrollHeight = 840

  ui.scrollMessageLog(container)

  assert.equal(container.scrollTop, 840)
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
