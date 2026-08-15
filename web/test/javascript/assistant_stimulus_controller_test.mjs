import test from "node:test"
import assert from "node:assert/strict"
import { register } from "node:module"
import { JSDOM } from "jsdom"

const initialDom = new JSDOM("<!doctype html><html><body></body></html>", {
  url: "http://localhost/",
})

function installGlobals(dom) {
  globalThis.window = dom.window
  globalThis.document = dom.window.document
  Object.defineProperty(globalThis, "navigator", {
    configurable: true,
    value: dom.window.navigator,
  })
  globalThis.Element = dom.window.Element
  globalThis.HTMLElement = dom.window.HTMLElement
  globalThis.Node = dom.window.Node
  globalThis.MutationObserver = dom.window.MutationObserver
  globalThis.CustomEvent = dom.window.CustomEvent
  globalThis.KeyboardEvent = dom.window.KeyboardEvent
  Object.defineProperty(dom.window, "innerWidth", { configurable: true, value: 1024 })
  Object.defineProperty(dom.window, "innerHeight", { configurable: true, value: 768 })
}

installGlobals(initialDom)
register("./support/assistant_controller_loader.mjs", import.meta.url)

const { Application } = await import("@hotwired/stimulus")
const AssistantController = (
  await import("../../app/javascript/controllers/assistant_controller.js")
).default

function deferred() {
  let resolve
  const promise = new Promise((resolver) => { resolve = resolver })
  return { promise, resolve }
}

function response(data, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    async text() { return data === null ? "" : JSON.stringify(data) },
  }
}

function conversation(id, title) {
  return {
    id,
    title,
    backend: "codex",
    brand: "openai",
    legacy: false,
    messages: [],
    turns: [],
    drafts: [],
  }
}

function fixture() {
  return `
    <div data-controller="assistant"
         data-assistant-openai-asset-value="/assets/assistant/openai.svg"
         data-assistant-anthropic-asset-value="/assets/assistant/anthropic.svg">
      <button data-assistant-target="bubble"></button>
      <section data-assistant-target="panel" hidden>
        <button data-assistant-target="resizeHandle"></button>
        <span data-assistant-target="resizeStatus"></span>
        <div data-assistant-target="historyWorkspace" data-history-collapsed="false">
          <aside id="hunter-assistant-history" data-assistant-target="historySidebar">
            <button data-assistant-target="historyToggle" aria-controls="hunter-assistant-history" aria-expanded="true">
              <span data-assistant-target="historyToggleLabel">Collapse</span>
            </button>
          </aside>
        </div>
        <div data-assistant-target="startScreen"></div>
        <div data-assistant-target="conversationScreen" hidden></div>
        <button data-assistant-target="providerButton" data-action="assistant#startConversation" data-backend="codex">
          <span data-provider-label>OpenAI</span><span data-provider-loading hidden>Starting…</span>
        </button>
        <button data-assistant-target="providerButton" data-action="assistant#startConversation" data-backend="claude_code">
          <span data-provider-label>Anthropic</span><span data-provider-loading hidden>Starting…</span>
        </button>
        <div data-assistant-target="providerStatus"></div>
        <div data-assistant-target="conversationList"></div>
        <div data-assistant-target="profileName"></div>
        <div data-assistant-target="messages"></div>
        <textarea data-assistant-target="messageInput"></textarea>
        <button data-assistant-target="sendButton"></button>
        <button data-assistant-target="cancelButton"></button>
        <select data-assistant-target="contextType"></select>
        <input data-assistant-target="contextQuery">
        <div data-assistant-target="contextResults"></div>
        <div data-assistant-target="disclosurePreview"></div>
        <div data-assistant-target="drafts"></div>
        <div data-assistant-target="status"></div>
        <div data-assistant-target="notice"></div>
        <details data-assistant-target="capabilityDisclosure"></details>
        <details data-assistant-target="contextDisclosure"></details>
        <div data-assistant-target="historyMenu" hidden>
          <button role="menuitem" data-assistant-target="historyMenuRename">Rename</button>
          <button role="menuitem" data-assistant-target="historyMenuMoveUp">Move up</button>
          <button role="menuitem" data-assistant-target="historyMenuMoveDown">Move down</button>
          <button role="menuitem">Delete</button>
        </div>
        <dialog data-assistant-target="renameDialog">
          <input data-assistant-target="renameInput">
          <button data-assistant-target="renameCancel">Cancel</button>
          <button data-assistant-target="renameSubmit">Rename</button>
        </dialog>
        <button data-assistant-target="fontDecrease"></button>
        <button data-assistant-target="fontIncrease"></button>
        <span data-assistant-target="fontScaleStatus"></span>
      </section>
    </div>
  `
}

async function tick() {
  await new Promise((resolve) => setTimeout(resolve, 0))
}

async function harness(fetchImpl = async () => response({})) {
  const dom = new JSDOM(`<!doctype html><html><head><meta name="csrf-token" content="test"></head><body>${fixture()}</body></html>`, {
    url: "http://localhost/",
  })
  installGlobals(dom)
  globalThis.fetch = fetchImpl
  dom.window.confirm = () => true

  const dialog = dom.window.document.querySelector("dialog")
  dialog.showModal = function showModal() {
    this.open = true
    this.setAttribute("open", "")
  }
  dialog.close = function close() {
    this.open = false
    this.removeAttribute("open")
  }

  const application = Application.start(dom.window.document.documentElement)
  application.register("assistant", AssistantController)
  await tick()
  const element = dom.window.document.querySelector('[data-controller="assistant"]')
  const controller = application.getControllerForElementAndIdentifier(element, "assistant")
  assert.ok(controller, "Stimulus controller connected")
  controller.bootstrap = {
    settings: { effective_enabled: true, conversation_management_enabled: true },
    chat_backends: [
      { slug: "codex", brand: "openai", enabled: true, reviewed_at: "2026-08-13T00:00:00Z", retention_posture: "standard" },
      { slug: "claude_code", brand: "anthropic", enabled: true, reviewed_at: "2026-08-13T00:00:00Z", retention_posture: "standard" },
    ],
  }
  return { application, controller, dom }
}

test("one-click creation sends one closed backend request and locks both controls", async () => {
  const create = deferred()
  const requests = []
  const { application, controller, dom } = await harness((url, options = {}) => {
    requests.push({ url, options })
    if (url === "/api/v1/assistant/conversations") {
      if (options.method === "POST") return create.promise
      return response({ conversations: [conversation(7, "New conversation")] })
    }
    throw new Error(`Unexpected request: ${options.method || "GET"} ${url}`)
  })
  controller.renderProviderButtons(controller.bootstrap.chat_backends)
  const [codexButton, claudeButton] = controller.providerButtonTargets

  const first = controller.startConversation({ preventDefault() {}, currentTarget: codexButton })
  const duplicate = controller.startConversation({ preventDefault() {}, currentTarget: codexButton })
  await tick()

  assert.equal(codexButton.disabled, true)
  assert.equal(claudeButton.disabled, true)
  assert.equal(codexButton.getAttribute("aria-busy"), "true")
  assert.equal(codexButton.querySelector("[data-provider-loading]").hidden, false)
  assert.equal(requests.filter(({ options }) => options.method === "POST").length, 1)
  assert.deepEqual(JSON.parse(requests[0].options.body), { backend: "codex" })

  create.resolve(response(conversation(7, "New conversation"), 201))
  await Promise.all([first, duplicate])

  assert.equal(dom.window.document.activeElement, controller.messageInputTarget)
  assert.equal(controller.currentConversation.backend, "codex")
  application.stop()
})

test("failed one-click creation restores both provider controls", async () => {
  const { application, controller } = await harness(async (url, options = {}) => {
    assert.equal(url, "/api/v1/assistant/conversations")
    assert.equal(options.method, "POST")
    return response({ error: "not_found" }, 404)
  })
  controller.renderProviderButtons(controller.bootstrap.chat_backends)
  const [codexButton, claudeButton] = controller.providerButtonTargets

  await controller.startConversation({ preventDefault() {}, currentTarget: claudeButton })

  assert.equal(codexButton.disabled, false)
  assert.equal(claudeButton.disabled, false)
  assert.equal(claudeButton.getAttribute("aria-busy"), "false")
  assert.equal(claudeButton.querySelector("[data-provider-loading]").hidden, true)
  application.stop()
})

test("legacy conversations remain readable with an archive identity and disabled composer", async () => {
  const { application, controller } = await harness()
  const legacy = { ...conversation(8, "Historical"), backend: null, brand: null, legacy: true }

  controller.renderConversation(legacy)

  assert.match(controller.profileNameTarget.textContent, /Legacy conversation/)
  assert.match(controller.profileNameTarget.textContent, /read-only/)
  assert.equal(controller.profileNameTarget.querySelector("img"), null)
  assert.equal(controller.messageInputTarget.disabled, true)
  assert.equal(controller.sendButtonTarget.disabled, true)
  application.stop()
})

test("history toggle gives the chat width and persists the preference", async () => {
  const { application, controller } = await harness()
  controller.historyCollapsed = false
  controller.applyHistoryState()

  controller.toggleHistory({ preventDefault() {} })

  assert.equal(controller.historyWorkspaceTarget.dataset.historyCollapsed, "true")
  assert.equal(controller.historyToggleTarget.getAttribute("aria-expanded"), "false")
  assert.match(controller.historyToggleTarget.getAttribute("aria-label"), /expand/i)
  assert.deepEqual(JSON.parse(window.localStorage.getItem("hunter:assistant-history-rail:v1")), {
    collapsed: true,
  })
  application.stop()
})

test("message code copy routes complete text through the controller", async () => {
  const { application, controller } = await harness()
  const copied = []
  Object.defineProperty(navigator, "clipboard", {
    configurable: true,
    value: { async writeText(text) { copied.push(text) } },
  })
  const source = Array.from({ length: 13 }, (_, index) => `line ${index}`).join("\n")

  controller.appendMessage({ role: "assistant", body: `\`\`\`text\n${source}\n\`\`\`` })
  controller.messagesTarget.querySelector('[data-code-action="copy"]').click()
  await tick()

  assert.equal(copied[0], `${source}\n`)
  assert.equal(controller.statusTarget.textContent, "Code copied.")
  application.stop()
})

test("code clipboard rejection reports a polite failure without throwing", async () => {
  const { application, controller } = await harness()
  Object.defineProperty(navigator, "clipboard", {
    configurable: true,
    value: { async writeText() { throw new Error("denied") } },
  })

  await assert.doesNotReject(() => controller.copyCode("complete source"))

  assert.equal(controller.statusTarget.textContent, "The code could not be copied.")
  application.stop()
})

test("an in-flight rename cannot be dismissed and restores focus after authoritative render", async () => {
  const patch = deferred()
  const { application, controller, dom } = await harness((url, options) => {
    assert.equal(url, "/api/v1/assistant/conversations/7")
    assert.equal(options.method, "PATCH")
    return patch.promise
  })

  const original = conversation(7, "Original")
  controller.panelTarget.hidden = false
  controller.renderConversationList([original])
  const oldMenuButton = controller.conversationListTarget.children[0].children[1]
  controller.openHistoryMenu(original, { clientX: 20, clientY: 20 }, oldMenuButton)
  controller.beginRename()
  controller.renameInputTarget.value = "Renamed"
  const submitted = controller.submitRename({ preventDefault() {} })

  let prevented = 0
  controller.cancelRename({ preventDefault() { prevented += 1 } })
  assert.equal(prevented, 1)
  assert.equal(controller.renameDialogTarget.open, true)
  assert.equal(controller.renameCancelTarget.disabled, true)
  assert.equal(controller.renameDialogTarget.getAttribute("aria-busy"), "true")
  controller.close()
  assert.equal(controller.panelTarget.hidden, false)

  patch.resolve(response(conversation(7, "Renamed")))
  await submitted

  const newRow = controller.conversationListTarget.children[0]
  assert.equal(newRow.children[0].textContent, "Renamed")
  assert.equal(controller.renameDialogTarget.open, false)
  assert.equal(dom.window.document.activeElement, newRow.children[1])
  assert.equal(controller.historyMutationToken, null)
  application.stop()
})

test("deleting invalidates a delayed selection so a deleted conversation cannot reappear", async () => {
  const delayedSelection = deferred()
  const original = conversation(7, "Delete me")
  const { application, controller } = await harness((url, options = {}) => {
    if (url === "/api/v1/assistant/conversations/7" && !options.method) {
      return delayedSelection.promise
    }
    if (url === "/api/v1/assistant/conversations/7" && options.method === "DELETE") {
      return response(null, 204)
    }
    if (url === "/api/v1/assistant/conversations") {
      return response({ conversations: [] })
    }
    throw new Error(`Unexpected request: ${options.method || "GET"} ${url}`)
  })

  controller.renderConversationList([original])
  const title = controller.conversationListTarget.children[0].children[0]
  const selecting = controller.selectConversation({ currentTarget: title })
  await controller.confirmAndDeleteConversation(original)
  delayedSelection.resolve(response(original))
  await selecting

  assert.equal(controller.currentConversation, null)
  assert.deepEqual(controller.conversations, [])
  assert.match(controller.conversationListTarget.textContent, /No conversations yet/)
  application.stop()
})

test("only the newest history refresh can replace the visible list", async () => {
  const first = deferred()
  const second = deferred()
  let requestCount = 0
  const { application, controller } = await harness((url) => {
    assert.equal(url, "/api/v1/assistant/conversations")
    requestCount += 1
    return requestCount === 1 ? first.promise : second.promise
  })

  const olderRefresh = controller.refreshConversationList()
  const newerRefresh = controller.refreshConversationList()
  second.resolve(response({ conversations: [conversation(2, "Newest")] }))
  await newerRefresh
  first.resolve(response({ conversations: [conversation(1, "Stale")] }))
  await olderRefresh

  assert.equal(controller.conversations[0].id, 2)
  assert.equal(controller.conversationListTarget.textContent.includes("Stale"), false)
  application.stop()
})

test("keyboard movement keeps focus on the moved conversation after persistence", async () => {
  const first = conversation(1, "First")
  const second = conversation(2, "Second")
  const { application, controller, dom } = await harness(async (url, options) => {
    assert.equal(url, "/api/v1/assistant/conversations/order")
    assert.deepEqual(JSON.parse(options.body), { conversation_ids: [2, 1] })
    return response({ conversations: [second, first] })
  })

  controller.renderConversationList([first, second])
  await controller.persistConversationOrder([second, first], { focusConversationId: 2 })

  const movedRow = controller.conversationListTarget.children[0]
  assert.equal(movedRow.dataset.conversationId, "2")
  assert.equal(dom.window.document.activeElement, movedRow.children[1])
  assert.equal(controller.historyMutationToken, null)
  application.stop()
})

test("history menu enforces move boundaries and supports arrow-key focus", async () => {
  const conversations = [conversation(1, "First"), conversation(2, "Middle"), conversation(3, "Last")]
  const { application, controller, dom } = await harness()
  controller.renderConversationList(conversations)

  const firstTrigger = controller.conversationListTarget.children[0].children[1]
  controller.openHistoryMenu(conversations[0], { clientX: 10, clientY: 10 }, firstTrigger)
  assert.equal(controller.historyMenuMoveUpTarget.disabled, true)
  assert.equal(controller.historyMenuMoveDownTarget.disabled, false)

  const middleTrigger = controller.conversationListTarget.children[1].children[1]
  controller.openHistoryMenu(conversations[1], { clientX: 10, clientY: 10 }, middleTrigger)
  assert.equal(controller.historyMenuMoveUpTarget.disabled, false)
  assert.equal(controller.historyMenuMoveDownTarget.disabled, false)
  assert.equal(dom.window.document.activeElement, controller.historyMenuRenameTarget)
  controller.handleHistoryMenuKeydown({ key: "ArrowDown", preventDefault() {} })
  assert.equal(dom.window.document.activeElement, controller.historyMenuMoveUpTarget)

  const lastTrigger = controller.conversationListTarget.children[2].children[1]
  controller.openHistoryMenu(conversations[2], { clientX: 10, clientY: 10 }, lastTrigger)
  assert.equal(controller.historyMenuMoveUpTarget.disabled, false)
  assert.equal(controller.historyMenuMoveDownTarget.disabled, true)
  application.stop()
})
