import { Controller } from "@hotwired/stimulus"
import { assistantApi } from "lib/assistant_api"
import {
  clampPanelSize,
  desktopPanel,
  loadPanelSize,
  resizeFromKeyboard,
  resizeFromPointer,
  savePanelSize,
} from "lib/assistant_panel_size"
import {
  appendContextDisclosure,
  appendDraftCard,
  appendMessage,
  applyComposerAvailability,
  LatestRequest,
  pollingDelay,
  composerSubmitIntent,
  renderDisabledNotice,
  renderConversationList as renderConversationListItems,
  saveConfirmationText,
  scrollMessageLog,
  terminalTurnStatus,
} from "lib/assistant_ui"

export default class extends Controller {
  static targets = [
    "bubble", "panel", "startScreen", "conversationScreen", "providerSelect",
    "retentionNotice", "conversationList", "profileName", "messages", "messageInput",
    "startButton", "sendButton", "cancelButton", "contextType", "contextQuery",
    "contextResults", "disclosurePreview", "drafts", "status", "notice",
    "resizeHandle", "capabilityDisclosure", "contextDisclosure",
  ]

  connect() {
    this.bootstrap = null
    this.currentConversation = null
    this.currentTurnId = null
    this.currentTurnStatus = null
    this.selectedContexts = []
    this.renderedMessageIds = new Set()
    this.draftSignature = null
    this.pollTimer = null
    this.pollFailureCount = 0
    this.conversationRequests = new LatestRequest()
    this.pollRequests = new LatestRequest()
    this.abortController = null
    this.panelSize = null
    this.resizeState = null
    this.boundResizeMove = (event) => this.resizePanel(event)
    this.boundResizeEnd = (event) => this.finishResize(event)
    this.boundViewportResize = () => this.handleViewportResize()
    window.addEventListener("resize", this.boundViewportResize)
    this.restorePanelSize()
  }

  disconnect() {
    this.stopResize({ persist: false })
    this.stopPolling()
    this.conversationRequests.invalidate()
    this.abortRequests()
    window.removeEventListener("resize", this.boundViewportResize)
    document.documentElement.classList.remove("overflow-hidden")
  }

  async open() {
    this.restorePanelSize()
    this.panelTarget.hidden = false
    this.panelTarget.setAttribute("aria-modal", String(this.mobilePanel()))
    this.bubbleTarget.setAttribute("aria-expanded", "true")
    if (this.mobilePanel()) document.documentElement.classList.add("overflow-hidden")
    if (!this.bootstrap) await this.loadBootstrap()
    if (this.currentTurnId && !terminalTurnStatus(this.currentTurnStatus)) this.schedulePoll()
    this.firstFocusable()?.focus()
  }

  close() {
    this.stopResize({ persist: true })
    this.panelTarget.hidden = true
    this.bubbleTarget.setAttribute("aria-expanded", "false")
    document.documentElement.classList.remove("overflow-hidden")
    if (this.currentTurnId && !terminalTurnStatus(this.currentTurnStatus)) this.schedulePoll()
    this.bubbleTarget.focus()
  }

  startResize(event) {
    if (!this.desktopPanel() || (event.button !== undefined && event.button !== 0)) return
    event.preventDefault()
    this.stopResize({ persist: false })

    const rect = this.panelTarget.getBoundingClientRect()
    this.resizeState = {
      pointerId: event.pointerId,
      startSize: { width: rect.width, height: rect.height },
      startPoint: { x: event.clientX, y: event.clientY },
    }
    this.resizeHandleTarget.setPointerCapture?.(event.pointerId)
    this.resizeHandleTarget.addEventListener("pointermove", this.boundResizeMove)
    this.resizeHandleTarget.addEventListener("pointerup", this.boundResizeEnd)
    this.resizeHandleTarget.addEventListener("pointercancel", this.boundResizeEnd)
    document.documentElement.classList.add("assistant-is-resizing")
  }

  resizePanel(event) {
    if (!this.resizeState || event.pointerId !== this.resizeState.pointerId) return
    const size = resizeFromPointer(
      this.resizeState.startSize,
      this.resizeState.startPoint,
      { x: event.clientX, y: event.clientY },
      this.viewport(),
    )
    this.applyPanelSize(size)
  }

  finishResize(event) {
    if (!this.resizeState || event.pointerId !== this.resizeState.pointerId) return
    this.stopResize({ persist: true })
  }

  stopResize({ persist }) {
    if (!this.resizeState) return
    const pointerId = this.resizeState.pointerId
    this.resizeHandleTarget.removeEventListener("pointermove", this.boundResizeMove)
    this.resizeHandleTarget.removeEventListener("pointerup", this.boundResizeEnd)
    this.resizeHandleTarget.removeEventListener("pointercancel", this.boundResizeEnd)
    if (this.resizeHandleTarget.hasPointerCapture?.(pointerId)) {
      this.resizeHandleTarget.releasePointerCapture(pointerId)
    }
    this.resizeState = null
    document.documentElement.classList.remove("assistant-is-resizing")
    if (persist && this.panelSize) savePanelSize(this.panelStorage(), this.panelSize)
  }

  resizeWithKeyboard(event) {
    if (!this.desktopPanel()) return
    const size = resizeFromKeyboard(
      this.currentPanelSize(),
      event.key,
      event.shiftKey ? 48 : 16,
      this.viewport(),
    )
    if (!size) return

    event.preventDefault()
    this.applyPanelSize(size)
    savePanelSize(this.panelStorage(), size)
  }

  handleViewportResize() {
    if (!this.desktopPanel()) {
      this.stopResize({ persist: false })
      this.panelSize = null
      this.panelTarget.style.removeProperty("width")
      this.panelTarget.style.removeProperty("height")
      this.resizeHandleTarget.setAttribute("aria-label", "Resize Hunter assistant")
      return
    }

    const size = this.panelSize
      ? clampPanelSize(this.panelSize, this.viewport())
      : loadPanelSize(this.panelStorage(), this.viewport())
    this.applyPanelSize(size)
    savePanelSize(this.panelStorage(), size)
  }

  restorePanelSize() {
    if (!this.desktopPanel()) return this.handleViewportResize()
    this.applyPanelSize(loadPanelSize(this.panelStorage(), this.viewport()))
  }

  applyPanelSize(size) {
    this.panelSize = {
      width: Math.round(size.width),
      height: Math.round(size.height),
    }
    this.panelTarget.style.width = `${this.panelSize.width}px`
    this.panelTarget.style.height = `${this.panelSize.height}px`
    this.resizeHandleTarget.setAttribute(
      "aria-label",
      `Resize Hunter assistant, current size ${this.panelSize.width} by ${this.panelSize.height} pixels`,
    )
  }

  currentPanelSize() {
    if (this.panelSize) return this.panelSize
    const rect = this.panelTarget.getBoundingClientRect()
    return { width: rect.width, height: rect.height }
  }

  panelStorage() {
    try {
      return window.localStorage
    } catch {
      return null
    }
  }

  viewport() {
    return { width: window.innerWidth, height: window.innerHeight }
  }

  desktopPanel() {
    return desktopPanel(this.viewport())
  }

  handleKeydown(event) {
    if (this.panelTarget.hidden) return
    if (event.key === "Escape") {
      event.preventDefault()
      this.close()
      return
    }
    if (event.key === "Tab" && this.mobilePanel()) this.trapFocus(event)
  }

  async loadBootstrap() {
    this.abortRequests()
    this.abortController = new AbortController()
    this.setStatus("Loading assistant…")
    try {
      const response = await assistantApi.bootstrap({ signal: this.abortController.signal })
      if (response.aborted) return
      if (!response.ok) return this.showRequestError(response)

      this.bootstrap = response.data
      this.populateProviders(response.data.provider_profiles || [])
      this.renderConversationList(response.data.conversations || [])
      this.showStartScreen()
      this.renderDisabledState(response.data.settings || {})
      this.setStatus("")
    } catch (error) {
      if (error.name !== "AbortError") this.setStatus("Assistant could not be loaded.")
    }
  }

  // The single source of truth for whether the assistant can accept input; both the
  // disabled notice and composer availability read it, so they cannot disagree.
  effectiveEnabled() {
    return this.bootstrap?.settings?.effective_enabled === true
  }

  renderDisabledState(settings) {
    if (settings.effective_enabled) {
      this.noticeTarget.hidden = true
      this.noticeTarget.textContent = ""
      return
    }

    renderDisabledNotice(this.noticeTarget, this.messageInputTarget, settings.disabled_reason)
    this.noticeTarget.hidden = false
  }

  updateRetentionNotice() {
    const selected = this.selectedProfile()
    const days = this.bootstrap?.settings?.transcript_retention_days
    const posture = selected?.retention_posture?.replaceAll("_", " ") || "not available"
    this.retentionNoticeTarget.textContent =
      `Hunter retains this encrypted conversation for ${days || "the configured number of"} days. ` +
      `Provider retention posture: ${posture}. Local deletion cannot erase provider or backup copies.`
  }

  async startConversation(event) {
    event.preventDefault()
    const profileId = this.providerSelectTarget.value
    if (!profileId) return this.setStatus("Select an enabled provider profile.")

    const requestToken = this.conversationRequests.issue()
    this.setStatus("Starting conversation…")
    const response = await assistantApi.createConversation(profileId, { signal: this.requestSignal() })
    if (response.aborted || !this.conversationRequests.current(requestToken)) return
    if (!response.ok) return this.showRequestError(response)

    this.currentConversation = response.data
    this.renderConversation(response.data)
    await this.refreshConversationList()
    this.messageInputTarget.focus()
  }

  async selectConversation(event) {
    const id = event.currentTarget.dataset.conversationId
    const requestToken = this.conversationRequests.issue()
    this.stopPolling()
    this.setStatus("Loading conversation…")
    const response = await assistantApi.getConversation(id, { signal: this.requestSignal() })
    if (response.aborted || !this.conversationRequests.current(requestToken)) return
    if (!response.ok) return this.showRequestError(response)

    this.currentConversation = response.data
    this.renderConversation(response.data)
    this.renderConversationList(this.conversations || [])
    this.setStatus("")
  }

  showNewConversation() {
    this.conversationRequests.invalidate()
    this.stopPolling()
    this.currentConversation = null
    this.currentTurnId = null
    this.currentTurnStatus = null
    this.showStartScreen()
    this.renderConversationList(this.conversations || [])
    this.providerSelectTarget.focus()
  }

  async submitMessage(event) {
    event.preventDefault()
    if (!this.currentConversation) return
    const message = this.messageInputTarget.value.trim()
    if (!message) return this.setStatus("Enter a message.")

    this.sendButtonTarget.disabled = true
    this.setStatus("Persisting and dispatching turn…")
    const contexts = this.selectedContexts.map(({ type, id }) => ({ type, id }))
    const response = await assistantApi.createTurn(
      this.currentConversation.id,
      message,
      contexts,
      { signal: this.requestSignal() }
    )
    if (response.aborted) return
    if (!response.ok && response.status !== 503) {
      this.sendButtonTarget.disabled = false
      return this.showRequestError(response)
    }

    if (response.data?.id) this.renderTurn(response.data)
    this.messageInputTarget.value = ""
    this.messageInputTarget.style.removeProperty("height")
    this.selectedContexts = []
    this.renderContextDisclosures()
    this.sendButtonTarget.disabled = false
    if (response.ok && !terminalTurnStatus(response.data.status)) this.schedulePoll()
    if (!response.ok) this.showRequestError(response)
  }

  async cancelTurn() {
    if (!this.currentTurnId || terminalTurnStatus(this.currentTurnStatus)) return
    this.stopPolling()
    this.cancelButtonTarget.disabled = true
    const response = await assistantApi.cancelTurn(this.currentTurnId, { signal: this.requestSignal() })
    if (response.aborted) return
    if (!response.ok) {
      this.cancelButtonTarget.disabled = false
      this.schedulePoll()
      return this.showRequestError(response)
    }

    this.renderTurn(response.data)
  }

  async findContexts() {
    if (!this.currentConversation) return
    const conversationId = this.currentConversation.id
    this.setStatus("Finding context…")
    const response = await assistantApi.contextOptions(
      this.contextTypeTarget.value,
      this.contextQueryTarget.value,
      { signal: this.requestSignal() }
    )
    if (response.aborted || conversationId !== this.currentConversation?.id) return
    if (!response.ok) return this.showRequestError(response)

    this.contextResultsTarget.replaceChildren()
    for (const option of response.data.options || []) {
      const button = document.createElement("button")
      button.type = "button"
      button.className = "block w-full rounded-lg border border-transparent px-2.5 py-2 text-left text-xs text-zinc-700 transition hover:border-zinc-200 hover:bg-white dark:text-zinc-300 dark:hover:border-white/10 dark:hover:bg-zinc-900"
      button.textContent = option.label
      button.addEventListener("click", () => this.attachContext(option))
      this.contextResultsTarget.appendChild(button)
    }
    this.setStatus("")
  }

  async attachContext(option) {
    if (this.selectedContexts.some(({ type, id }) => type === option.type && String(id) === String(option.id))) {
      return this.setStatus("That context is already selected.")
    }
    if (this.selectedContexts.length >= 10) return this.setStatus("At most ten records may be disclosed.")

    const conversationId = this.currentConversation?.id
    const reference = { type: option.type, id: String(option.id) }
    const response = await assistantApi.previewContexts([reference], { signal: this.requestSignal() })
    if (response.aborted || conversationId !== this.currentConversation?.id) return
    if (!response.ok) return this.showRequestError(response)

    this.selectedContexts.push({
      ...reference,
      label: option.label,
      preview: response.data.previews[0],
    })
    this.contextResultsTarget.replaceChildren()
    this.renderContextDisclosures()
  }

  renderContextDisclosures() {
    this.disclosurePreviewTarget.replaceChildren()
    for (const context of this.selectedContexts) {
      appendContextDisclosure(document, this.disclosurePreviewTarget, context, (removed) => {
        this.selectedContexts = this.selectedContexts.filter((item) =>
          !(item.type === removed.type && item.id === removed.id)
        )
        this.renderContextDisclosures()
      })
    }
    this.disclosurePreviewTarget.hidden = this.selectedContexts.length === 0
  }

  async deleteConversation() {
    if (!this.currentConversation) return
    const response = await assistantApi.deleteConversation(
      this.currentConversation.id,
      { signal: this.requestSignal() }
    )
    if (response.aborted) return
    if (!response.ok) return this.showRequestError(response)

    this.conversationRequests.invalidate()
    this.stopPolling()
    this.currentConversation = null
    this.currentTurnId = null
    this.showStartScreen()
    await this.refreshConversationList()
    this.setStatus("Conversation deleted.")
  }

  populateProviders(profiles) {
    this.providerSelectTarget.replaceChildren()
    const enabledProfiles = profiles.filter((profile) => profile.enabled && profile.reviewed_at)
    const assistantEnabled = this.effectiveEnabled()
    const prompt = document.createElement("option")
    prompt.value = ""
    if (!assistantEnabled) {
      prompt.textContent = "Assistant is disabled"
    } else {
      prompt.textContent = enabledProfiles.length ? "Select a reviewed profile" : "No enabled profiles"
    }
    this.providerSelectTarget.appendChild(prompt)

    enabledProfiles.forEach((profile) => {
      const option = document.createElement("option")
      option.value = String(profile.id)
      option.textContent = `${profile.name} · ${profile.provider} ${profile.model}`
      this.providerSelectTarget.appendChild(option)
    })
    this.providerSelectTarget.disabled = !assistantEnabled || enabledProfiles.length === 0
    this.startButtonTarget.disabled = this.providerSelectTarget.disabled
    this.updateRetentionNotice()
  }

  renderConversationList(conversations) {
    this.conversations = conversations
    renderConversationListItems(document, this.conversationListTarget, conversations, {
      currentId: this.currentConversation?.id,
      onSelect: (_conversation, event) => this.selectConversation(event),
    })
  }

  handleComposerKeydown(event) {
    if (!composerSubmitIntent(event)) return
    event.preventDefault()
    event.currentTarget.form?.requestSubmit()
  }

  autosizeComposer(event) {
    const input = event.currentTarget
    input.style.height = "auto"
    input.style.height = `${Math.min(input.scrollHeight, 160)}px`
  }

  renderConversation(conversation) {
    this.startScreenTarget.hidden = true
    this.conversationScreenTarget.hidden = false
    this.profileNameTarget.textContent =
      `${conversation.provider_profile.name} · ${conversation.provider_profile.provider} ${conversation.provider_profile.model}`
    this.messagesTarget.replaceChildren()
    this.renderedMessageIds = new Set()
    for (const message of conversation.messages || []) this.appendMessage(message)
    this.selectedContexts = []
    this.renderContextDisclosures()
    this.contextResultsTarget.replaceChildren()
    this.draftsTarget.replaceChildren()
    this.draftSignature = null
    this.renderDrafts(conversation.drafts || [])
    applyComposerAvailability(
      this.messageInputTarget, this.sendButtonTarget, this.effectiveEnabled()
    )

    const turns = conversation.turns || []
    const active = [...turns].reverse().find((turn) => !terminalTurnStatus(turn.status))
    this.currentTurnId = active?.id || null
    this.currentTurnStatus = active?.status || null
    this.cancelButtonTarget.hidden = !active
    this.cancelButtonTarget.disabled = false
    if (active) this.schedulePoll()
  }

  appendMessage(message) {
    if (message.id && this.renderedMessageIds.has(message.id)) return
    appendMessage(document, this.messagesTarget, message)
    if (message.id) this.renderedMessageIds.add(message.id)
    scrollMessageLog(this.messagesTarget)
  }

  renderTurn(turn) {
    this.currentTurnId = turn.id
    this.currentTurnStatus = turn.status
    for (const message of turn.messages || []) this.appendMessage(message)
    this.renderDrafts(turn.drafts || [])
    const terminal = terminalTurnStatus(turn.status)
    this.cancelButtonTarget.hidden = terminal
    this.cancelButtonTarget.disabled = terminal
    if (terminal) this.stopPolling()
    this.setStatus(this.turnStatusMessage(turn))
  }

  async renderDrafts(summaries) {
    const signature = summaries.map((draft) => `${draft.id}:${draft.updated_at || ""}`).join("|")
    if (signature === this.draftSignature) return
    this.draftSignature = signature
    const responses = await Promise.all(summaries.map((draft) =>
      assistantApi.getDraft(draft.id, { signal: this.requestSignal() })
    ))
    if (signature !== this.draftSignature) return

    this.draftsTarget.replaceChildren()
    for (const response of responses) {
      if (!response.ok) continue
      appendDraftCard(document, this.draftsTarget, response.data, {
        onCopy: (draft) => this.copyDraft(draft),
        onOpenEditor: (draft) => this.openDraftEditor(draft),
        onSave: (draft) => this.confirmDraftSave(draft),
      })
    }
  }

  async copyDraft(draft) {
    try {
      await navigator.clipboard.writeText(draft.content)
      this.setStatus("Draft copied.")
    } catch {
      this.setStatus("The draft could not be copied.")
    }
  }

  async confirmDraftSave(draft) {
    if (!window.confirm(saveConfirmationText(draft))) {
      this.setStatus("Draft save canceled.")
      return
    }

    this.setStatus("Revalidating and saving reviewed draft…")
    const response = await assistantApi.confirmSave(draft.id, {
      name: draft.name,
      content_digest: draft.content_digest,
      validation_version: draft.validation?.version,
      diff_digest: draft.diff_digest ?? null,
      destination: draft.destination ?? null,
    }, { signal: this.requestSignal() })
    if (response.aborted) return
    if (!response.ok) return this.showRequestError(response)

    draft.can_save = false
    this.setStatus("Draft saved. No job, run, send, schedule, or execution was started.")
  }

  openDraftEditor(draft) {
    const path = draft.artifact_type === "ansible_playbook"
      ? "/control_center/ansible/playbooks"
      : "/control_center/templates"
    window.open(`${path}?assistant_draft_id=${encodeURIComponent(draft.id)}`, "_blank", "noopener")
  }

  async pollTurn(requestToken) {
    this.clearPoll()
    if (!this.pollRequests.current(requestToken) || !this.currentTurnId || terminalTurnStatus(this.currentTurnStatus)) return
    const turnId = this.currentTurnId
    const response = await assistantApi.getTurn(turnId, { signal: this.requestSignal() })
    if (response.aborted || !this.pollRequests.current(requestToken) || turnId !== this.currentTurnId) return
    if (!response.ok) {
      this.pollFailureCount += 1
      this.setStatus("Turn status is temporarily unavailable.")
      return this.schedulePoll()
    }

    this.pollFailureCount = 0
    this.renderTurn(response.data)
    if (!terminalTurnStatus(response.data.status)) this.schedulePoll()
  }

  schedulePoll() {
    this.clearPoll()
    if (!this.currentTurnId || terminalTurnStatus(this.currentTurnStatus)) return
    const requestToken = this.pollRequests.issue()
    const delay = pollingDelay({
      panelOpen: !this.panelTarget.hidden,
      failureCount: this.pollFailureCount,
    })
    this.pollTimer = window.setTimeout(() => this.pollTurn(requestToken), delay)
  }

  clearPoll() {
    if (this.pollTimer) window.clearTimeout(this.pollTimer)
    this.pollTimer = null
  }

  stopPolling() {
    this.clearPoll()
    this.pollRequests.invalidate()
  }

  turnStatusMessage(turn) {
    switch (turn.status) {
    case "created": return "Turn persisted."
    case "queued": return "Turn queued."
    case "running": return "Assistant is drafting…"
    case "completed": return "Turn completed."
    case "canceled": return "Turn canceled."
    case "interrupted": return "Dispatch was interrupted. Retry to create a new turn."
    case "failed": return `Turn failed: ${turn.error_code || "assistant_error"}.`
    default: return "Turn status unavailable."
    }
  }

  showStartScreen() {
    this.startScreenTarget.hidden = false
    this.conversationScreenTarget.hidden = true
    this.updateRetentionNotice()
  }

  async refreshConversationList() {
    const response = await assistantApi.listConversations({ signal: this.requestSignal() })
    if (response.aborted) return
    if (response.ok) this.renderConversationList(response.data.conversations || [])
  }

  selectedProfile() {
    const id = Number(this.providerSelectTarget.value)
    return this.bootstrap?.provider_profiles?.find((profile) => profile.id === id)
  }

  showRequestError(response) {
    const code = response.data?.error
    const message = code === "assistant_disabled"
      ? "The assistant kill switch is off."
      : code === "assistant_dispatch_unavailable"
        ? "Dispatch was interrupted. Retry to create a new turn."
      : code === "context_invalid"
          ? "One selected context record is unavailable or unsafe."
          : code === "destination_stale"
            ? "The destination changed. Review a fresh diff before saving."
            : code === "confirmation_mismatch"
              ? "The reviewed draft changed. Review it again before saving."
              : code === "validation_failed"
                ? "Current server validation rejected the draft."
          : "The assistant request was rejected."
    this.setStatus(message)
  }

  setStatus(message) {
    this.statusTarget.textContent = message
    this.statusTarget.hidden = !message
  }

  abortRequests() {
    this.abortController?.abort()
    this.abortController = null
  }

  requestSignal() {
    this.abortController ||= new AbortController()
    return this.abortController.signal
  }

  mobilePanel() {
    return !this.desktopPanel()
  }

  focusableElements() {
    return [...this.panelTarget.querySelectorAll(
      'button:not([disabled]), select:not([disabled]), textarea:not([disabled]), input:not([disabled]), [href], [tabindex]:not([tabindex="-1"])'
    )].filter((element) =>
      !element.closest("[hidden]") && window.getComputedStyle(element).display !== "none"
    )
  }

  firstFocusable() {
    return this.panelTarget.querySelector("[data-assistant-initial-focus]") || this.focusableElements()[0]
  }

  trapFocus(event) {
    const focusable = this.focusableElements()
    if (focusable.length === 0) return
    const first = focusable[0]
    const last = focusable.at(-1)
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault()
      last.focus()
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault()
      first.focus()
    }
  }
}
