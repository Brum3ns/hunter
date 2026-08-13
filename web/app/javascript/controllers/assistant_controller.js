import { Controller } from "@hotwired/stimulus"
import { assistantApi } from "lib/assistant_api"
import {
  changeFontScale,
  FONT_SCALES,
  loadFontScaleIndex,
  saveFontScaleIndex,
} from "lib/assistant_font_scale"
import {
  conversationIds,
  moveConversation,
  reorderConversation,
} from "lib/assistant_history"
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
  conversationDeletionText,
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
    "resizeHandle", "resizeStatus", "capabilityDisclosure", "contextDisclosure",
    "historyMenu", "historyMenuRename", "historyMenuMoveUp", "historyMenuMoveDown",
    "renameDialog", "renameInput", "renameSubmit", "renameCancel",
    "fontDecrease", "fontIncrease", "fontScaleStatus",
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
    this.historyListRequests = new LatestRequest()
    this.abortController = null
    this.panelSize = null
    this.resizeState = null
    this.historyMenuConversation = null
    this.historyMenuTrigger = null
    this.renameConversation = null
    this.renameTrigger = null
    this.renameFocusControl = "title"
    this.draggedConversationId = null
    this.reorderInFlight = false
    this.deleteInFlightIds = new Set()
    this.historyMutationToken = null
    this.activeSelectionToken = null
    this.resumePollingAfterHistoryMutation = false
    this.renameInFlight = false
    this.fontScaleIndex = loadFontScaleIndex(this.panelStorage())
    this.boundResizeMove = (event) => this.resizePanel(event)
    this.boundResizeEnd = (event) => this.finishResize(event)
    this.boundViewportResize = () => this.handleViewportResize()
    this.boundOutsideHistoryMenu = (event) => this.dismissHistoryMenu(event)
    window.addEventListener("resize", this.boundViewportResize)
    document.addEventListener("pointerdown", this.boundOutsideHistoryMenu)
    this.restorePanelSize()
    this.applyFontScale()
  }

  disconnect() {
    this.stopResize({ persist: false })
    this.stopPolling()
    this.conversationRequests.invalidate()
    this.historyListRequests.invalidate()
    this.abortRequests()
    this.closeHistoryMenu({ restoreFocus: false })
    if (this.hasRenameDialogTarget && this.renameDialogTarget.open) this.renameDialogTarget.close()
    window.removeEventListener("resize", this.boundViewportResize)
    document.removeEventListener("pointerdown", this.boundOutsideHistoryMenu)
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
    this.closeHistoryMenu({ restoreFocus: false })
    if (this.hasRenameDialogTarget && this.renameDialogTarget.open) {
      this.cancelRename()
      if (this.renameInFlight) return
    }
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
    this.resizeHandleTarget.addEventListener("lostpointercapture", this.boundResizeEnd)
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
    this.announcePanelSize()
  }

  stopResize({ persist }) {
    if (!this.resizeState) return
    const pointerId = this.resizeState.pointerId
    this.resizeHandleTarget.removeEventListener("pointermove", this.boundResizeMove)
    this.resizeHandleTarget.removeEventListener("pointerup", this.boundResizeEnd)
    this.resizeHandleTarget.removeEventListener("pointercancel", this.boundResizeEnd)
    this.resizeHandleTarget.removeEventListener("lostpointercapture", this.boundResizeEnd)
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
    this.announcePanelSize()
  }

  handleViewportResize() {
    if (!this.desktopPanel()) {
      this.stopResize({ persist: false })
      this.panelSize = null
      this.panelTarget.style.removeProperty("width")
      this.panelTarget.style.removeProperty("height")
      this.resizeStatusTarget.textContent = ""
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
  }

  announcePanelSize() {
    if (!this.panelSize) return
    this.resizeStatusTarget.textContent =
      `Current size ${this.panelSize.width} by ${this.panelSize.height} pixels.`
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
    if (this.hasRenameDialogTarget && this.renameDialogTarget.open) return
    if (event.key === "Escape") {
      event.preventDefault()
      if (!this.historyMenuTarget.hidden) {
        this.closeHistoryMenu()
        return
      }
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

  conversationManagementEnabled() {
    return this.effectiveEnabled() &&
      this.bootstrap?.settings?.conversation_management_enabled === true
  }

  beginHistoryMutation() {
    if (this.historyMutationToken) {
      this.setStatus("Another conversation change is still being saved.")
      return null
    }

    const token = Symbol("assistant-history-mutation")
    this.historyMutationToken = token
    this.resumePollingAfterHistoryMutation = this.activeSelectionToken !== null &&
      this.currentTurnId !== null && !terminalTurnStatus(this.currentTurnStatus)
    this.activeSelectionToken = null
    this.conversationRequests.invalidate()
    this.historyListRequests.invalidate()
    return token
  }

  finishHistoryMutation(token) {
    if (this.historyMutationToken !== token) return
    this.historyMutationToken = null
    if (this.resumePollingAfterHistoryMutation && this.currentTurnId &&
        !terminalTurnStatus(this.currentTurnStatus)) this.schedulePoll()
    this.resumePollingAfterHistoryMutation = false
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
    const mutationToken = this.beginHistoryMutation()
    if (!mutationToken) return

    this.setStatus("Starting conversation…")
    try {
      const response = await assistantApi.createConversation(profileId, { signal: this.requestSignal() })
      if (response.aborted) return
      if (!response.ok) return this.showRequestError(response)

      this.currentConversation = response.data
      this.renderConversation(response.data)
      await this.refreshConversationList()
      this.messageInputTarget.focus()
    } finally {
      this.finishHistoryMutation(mutationToken)
    }
  }

  async selectConversation(event) {
    this.closeHistoryMenu({ restoreFocus: false })
    if (this.historyMutationToken) {
      this.setStatus("Wait for the conversation change to finish.")
      return
    }
    const id = event.currentTarget.dataset.conversationId
    const requestToken = this.conversationRequests.issue()
    this.activeSelectionToken = requestToken
    this.stopPolling()
    this.setStatus("Loading conversation…")
    const response = await assistantApi.getConversation(id, { signal: this.requestSignal() })
    if (this.activeSelectionToken === requestToken) this.activeSelectionToken = null
    if (response.aborted || !this.conversationRequests.current(requestToken)) return
    if (!response.ok) return this.showRequestError(response)

    this.currentConversation = response.data
    this.renderConversation(response.data)
    this.renderConversationList(this.conversations || [])
    this.setStatus("")
  }

  showNewConversation() {
    this.closeHistoryMenu({ restoreFocus: false })
    if (this.historyMutationToken) {
      this.setStatus("Wait for the conversation change to finish.")
      return
    }
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
    if (this.sendButtonTarget.disabled) return
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
    await this.confirmAndDeleteConversation(this.currentConversation)
  }

  async deleteHistoryConversation() {
    const conversation = this.historyMenuConversation
    this.closeHistoryMenu({ restoreFocus: false })
    if (!conversation) return
    await this.confirmAndDeleteConversation(conversation)
  }

  async confirmAndDeleteConversation(conversation) {
    const conversationId = String(conversation.id)
    if (this.deleteInFlightIds.has(conversationId)) return
    if (!window.confirm(conversationDeletionText(conversation))) {
      this.setStatus("Conversation deletion canceled.")
      return
    }

    const mutationToken = this.beginHistoryMutation()
    if (!mutationToken) return
    this.deleteInFlightIds.add(conversationId)
    try {
      const response = await assistantApi.deleteConversation(conversation.id, {
        signal: this.requestSignal(),
      })
      if (response.aborted) return
      if (!response.ok) return this.showRequestError(response)

      const deletedCurrent = String(this.currentConversation?.id) === conversationId
      if (deletedCurrent) {
        this.stopPolling()
        this.currentConversation = null
        this.currentTurnId = null
        this.currentTurnStatus = null
        this.showStartScreen()
      }
      await this.refreshConversationList()
      this.setStatus("Conversation deleted.")
      if (deletedCurrent) {
        this.providerSelectTarget.focus()
      } else {
        this.focusConversationControl(this.currentConversation?.id)
      }
    } finally {
      this.deleteInFlightIds.delete(conversationId)
      this.finishHistoryMutation(mutationToken)
    }
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
      onContextMenu: (conversation, event, trigger) =>
        this.openHistoryMenu(conversation, event, trigger),
      onMenu: (conversation, event, trigger) =>
        this.openHistoryMenu(conversation, event, trigger),
      onDragStart: (conversation, event, row) =>
        this.startHistoryDrag(conversation, event, row),
      onDragOver: (conversation, event, row) =>
        this.dragHistoryOver(conversation, event, row),
      onDrop: (conversation, event, row) =>
        this.dropHistoryConversation(conversation, event, row),
      onDragEnd: () => this.endHistoryDrag(),
    })
  }

  openHistoryMenu(conversation, event, trigger) {
    this.closeHistoryMenu({ restoreFocus: false })
    this.historyMenuConversation = conversation
    this.historyMenuTrigger = trigger

    const index = (this.conversations || []).findIndex((item) =>
      String(item.id) === String(conversation.id)
    )
    const canOrganize = this.conversationManagementEnabled() &&
      !this.reorderInFlight && !this.historyMutationToken
    this.historyMenuRenameTarget.disabled = !canOrganize
    this.historyMenuMoveUpTarget.disabled = !canOrganize || index <= 0
    this.historyMenuMoveDownTarget.disabled = !canOrganize ||
      index < 0 || index >= (this.conversations || []).length - 1
    this.historyMenuTarget.hidden = false
    trigger?.setAttribute("aria-expanded", "true")

    const triggerRect = trigger?.getBoundingClientRect?.() || { left: 8, bottom: 8 }
    const desiredLeft = Number.isFinite(event?.clientX) && event.clientX > 0
      ? event.clientX
      : triggerRect.left
    const desiredTop = Number.isFinite(event?.clientY) && event.clientY > 0
      ? event.clientY
      : triggerRect.bottom
    const menuRect = this.historyMenuTarget.getBoundingClientRect()
    const left = Math.max(8, Math.min(desiredLeft, window.innerWidth - menuRect.width - 8))
    const top = Math.max(8, Math.min(desiredTop, window.innerHeight - menuRect.height - 8))
    this.historyMenuTarget.style.left = `${Math.round(left)}px`
    this.historyMenuTarget.style.top = `${Math.round(top)}px`
    this.historyMenuTarget.querySelector("button:not([disabled])")?.focus()
  }

  closeHistoryMenu({ restoreFocus = true } = {}) {
    if (!this.hasHistoryMenuTarget || this.historyMenuTarget.hidden) return
    const trigger = this.historyMenuTrigger
    this.historyMenuTarget.hidden = true
    this.historyMenuTarget.style.removeProperty("left")
    this.historyMenuTarget.style.removeProperty("top")
    trigger?.setAttribute("aria-expanded", "false")
    this.historyMenuConversation = null
    this.historyMenuTrigger = null
    if (restoreFocus && trigger?.isConnected) trigger.focus()
  }

  dismissHistoryMenu(event) {
    if (!this.hasHistoryMenuTarget || this.historyMenuTarget.hidden) return
    if (this.historyMenuTarget.contains(event.target)) return
    if (this.historyMenuTrigger?.contains?.(event.target)) return
    this.closeHistoryMenu({ restoreFocus: false })
  }

  handleHistoryMenuKeydown(event) {
    const items = [...this.historyMenuTarget.querySelectorAll('[role="menuitem"]:not([disabled])')]
    if (event.key === "Escape") {
      event.preventDefault()
      event.stopPropagation()
      this.closeHistoryMenu()
      return
    }
    if (event.key === "Tab") {
      this.closeHistoryMenu({ restoreFocus: false })
      return
    }
    if (!["ArrowDown", "ArrowUp", "Home", "End"].includes(event.key) || items.length === 0) return

    event.preventDefault()
    const index = items.indexOf(document.activeElement)
    const nextIndex = event.key === "Home"
      ? 0
      : event.key === "End"
        ? items.length - 1
        : event.key === "ArrowDown"
          ? (index + 1 + items.length) % items.length
          : (index - 1 + items.length) % items.length
    items[nextIndex].focus()
  }

  beginRename() {
    if (!this.conversationManagementEnabled() || !this.historyMenuConversation ||
        this.historyMutationToken) return
    this.renameConversation = this.historyMenuConversation
    this.renameTrigger = this.historyMenuTrigger
    this.renameFocusControl = this.historyMenuTrigger?.getAttribute("aria-haspopup") === "menu"
      ? "menu"
      : "title"
    this.renameInputTarget.value = this.renameConversation.title || ""
    this.closeHistoryMenu({ restoreFocus: false })
    this.renameDialogTarget.showModal()
    this.renameInputTarget.focus()
    this.renameInputTarget.select()
  }

  cancelRename(event) {
    event?.preventDefault?.()
    if (this.renameInFlight) {
      this.setStatus("Wait for the rename to finish.")
      return
    }
    this.resetRenameDialog()
  }

  resetRenameDialog({ restoreFocus = true } = {}) {
    const trigger = this.renameTrigger
    this.renameConversation = null
    this.renameTrigger = null
    this.renameFocusControl = "title"
    this.renameSubmitTarget.disabled = false
    this.renameCancelTarget.disabled = false
    this.renameDialogTarget.removeAttribute("aria-busy")
    this.renameInputTarget.setCustomValidity("")
    if (this.renameDialogTarget.open) this.renameDialogTarget.close()
    if (restoreFocus && trigger?.isConnected && !this.panelTarget.hidden) trigger.focus()
  }

  async submitRename(event) {
    event.preventDefault()
    const conversation = this.renameConversation
    const title = this.renameInputTarget.value.trim()
    if (!conversation || !this.conversationManagementEnabled()) return
    if (!title) {
      this.renameInputTarget.setCustomValidity("Enter a conversation title.")
      this.renameInputTarget.reportValidity()
      return
    }
    const mutationToken = this.beginHistoryMutation()
    if (!mutationToken) return

    this.renameInputTarget.setCustomValidity("")
    this.renameSubmitTarget.disabled = true
    this.renameCancelTarget.disabled = true
    this.renameDialogTarget.setAttribute("aria-busy", "true")
    this.renameInFlight = true
    const focusControl = this.renameFocusControl
    try {
      const response = await assistantApi.renameConversation(
        conversation.id,
        title,
        { signal: this.requestSignal() }
      )
      if (response.aborted) return
      if (!response.ok) {
        if (response.status === 422) {
          this.renameInputTarget.setCustomValidity("Use a title between 1 and 200 characters.")
          this.renameInputTarget.reportValidity()
          this.setStatus("Conversation title was rejected.")
          return
        }
        return this.showRequestError(response)
      }

      const renamed = response.data
      this.conversations = (this.conversations || []).map((item) =>
        String(item.id) === String(renamed.id) ? renamed : item
      )
      if (String(this.currentConversation?.id) === String(renamed.id)) {
        this.currentConversation = { ...this.currentConversation, title: renamed.title }
      }
      this.resetRenameDialog({ restoreFocus: false })
      this.renderConversationList(this.conversations)
      this.focusConversationControl(renamed.id, focusControl)
      this.setStatus("Conversation renamed.")
    } finally {
      this.renameInFlight = false
      this.renameSubmitTarget.disabled = false
      this.renameCancelTarget.disabled = false
      this.renameDialogTarget.removeAttribute("aria-busy")
      this.finishHistoryMutation(mutationToken)
    }
  }

  moveHistoryUp() {
    this.moveHistoryConversation(-1)
  }

  moveHistoryDown() {
    this.moveHistoryConversation(1)
  }

  async moveHistoryConversation(direction) {
    const conversation = this.historyMenuConversation
    this.closeHistoryMenu({ restoreFocus: false })
    if (!conversation || !this.conversationManagementEnabled() ||
        this.reorderInFlight || this.historyMutationToken) return
    await this.persistConversationOrder(
      moveConversation(this.conversations || [], conversation.id, direction),
      { focusConversationId: conversation.id },
    )
  }

  startHistoryDrag(conversation, event, row) {
    if (!this.conversationManagementEnabled() || this.reorderInFlight || this.historyMutationToken) {
      event.preventDefault()
      this.setStatus("Conversation reordering is disabled.")
      return
    }
    this.closeHistoryMenu({ restoreFocus: false })
    this.draggedConversationId = conversation.id
    row.classList.add("opacity-60")
    event.dataTransfer?.setData("text/plain", String(conversation.id))
    if (event.dataTransfer) event.dataTransfer.effectAllowed = "move"
  }

  dragHistoryOver(conversation, event, row) {
    if (this.draggedConversationId === null ||
        String(this.draggedConversationId) === String(conversation.id)) return
    event.preventDefault()
    if (event.dataTransfer) event.dataTransfer.dropEffect = "move"
    this.clearHistoryDropIndicators()
    const rect = row.getBoundingClientRect()
    const placement = event.clientY < rect.top + rect.height / 2 ? "before" : "after"
    row.dataset.dropPlacement = placement
    row.classList.add(placement === "before" ? "border-t-white" : "border-b-white")
  }

  async dropHistoryConversation(conversation, event, row) {
    if (this.draggedConversationId === null) return
    event.preventDefault()
    const placement = row.dataset.dropPlacement || "before"
    const next = reorderConversation(
      this.conversations || [],
      this.draggedConversationId,
      conversation.id,
      placement,
    )
    this.endHistoryDrag()
    await this.persistConversationOrder(next)
  }

  endHistoryDrag() {
    this.draggedConversationId = null
    this.clearHistoryDropIndicators()
    this.conversationListTarget.querySelectorAll(".opacity-60").forEach((row) =>
      row.classList.remove("opacity-60")
    )
  }

  clearHistoryDropIndicators() {
    this.conversationListTarget.querySelectorAll("[data-drop-placement]").forEach((row) => {
      row.classList.remove("border-t-white", "border-b-white")
      delete row.dataset.dropPlacement
    })
  }

  async persistConversationOrder(next, { focusConversationId = null } = {}) {
    if (this.reorderInFlight || this.historyMutationToken ||
        !this.conversationManagementEnabled()) return
    const before = [...(this.conversations || [])]
    const beforeIds = conversationIds(before).map(String)
    const nextIds = conversationIds(next).map(String)
    if (beforeIds.join("\u0000") === nextIds.join("\u0000")) return
    const mutationToken = this.beginHistoryMutation()
    if (!mutationToken) return

    this.reorderInFlight = true
    this.renderConversationList(next)
    if (focusConversationId !== null) this.focusConversationControl(focusConversationId, "menu")
    this.setStatus("Saving conversation order…")
    try {
      const response = await assistantApi.reorderConversations(
        conversationIds(next),
        { signal: this.requestSignal() }
      )
      if (response.aborted) {
        this.renderConversationList(before)
        if (focusConversationId !== null) this.focusConversationControl(focusConversationId, "menu")
        return
      }
      if (!response.ok) {
        this.renderConversationList(before)
        if (response.status === 409) await this.refreshConversationList()
        if (focusConversationId !== null) this.focusConversationControl(focusConversationId, "menu")
        return this.showRequestError(response)
      }

      this.renderConversationList(response.data.conversations || next)
      if (focusConversationId !== null) this.focusConversationControl(focusConversationId, "menu")
      this.setStatus("Conversation order saved.")
    } finally {
      this.reorderInFlight = false
      this.finishHistoryMutation(mutationToken)
    }
  }

  focusConversationControl(conversationId, control = "title") {
    const rows = [...this.conversationListTarget.children]
    const row = conversationId === null || conversationId === undefined
      ? rows[0]
      : rows.find((item) => String(item.dataset.conversationId) === String(conversationId))
    const target = row?.children[control === "menu" ? 1 : 0]
    target?.focus()
    return Boolean(target)
  }

  handleComposerKeydown(event) {
    if (!composerSubmitIntent(event)) return
    event.preventDefault()
    if (this.sendButtonTarget.disabled) return
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
    appendMessage(document, this.messagesTarget, message, {
      onCopy: (copiedMessage) => this.copyMessage(copiedMessage),
    })
    if (message.id) this.renderedMessageIds.add(message.id)
    scrollMessageLog(this.messagesTarget)
  }

  async copyMessage(message) {
    try {
      await navigator.clipboard.writeText(String(message?.body || ""))
      this.setStatus("Message copied.")
    } catch {
      this.setStatus("The message could not be copied.")
    }
  }

  decreaseFontScale() {
    this.updateFontScale(-1)
  }

  increaseFontScale() {
    this.updateFontScale(1)
  }

  updateFontScale(delta) {
    const next = changeFontScale(this.fontScaleIndex, delta)
    this.fontScaleIndex = next.index
    saveFontScaleIndex(this.panelStorage(), this.fontScaleIndex)
    this.applyFontScale()
  }

  applyFontScale() {
    const value = FONT_SCALES[this.fontScaleIndex] || 1
    this.panelTarget.style.setProperty("--assistant-message-scale", String(value))
    if (!this.hasFontScaleStatusTarget) return
    this.fontScaleStatusTarget.textContent = `${value * 100}%`
    this.fontDecreaseTarget.disabled = this.fontScaleIndex <= 0
    this.fontIncreaseTarget.disabled = this.fontScaleIndex >= FONT_SCALES.length - 1
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
    const requestToken = this.historyListRequests.issue()
    const response = await assistantApi.listConversations({ signal: this.requestSignal() })
    if (response.aborted || !this.historyListRequests.current(requestToken)) return
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
      : code === "conversation_management_disabled"
        ? "Conversation renaming and reordering are disabled."
      : code === "conversation_order_stale"
        ? "Conversation history changed. The current order was reloaded."
      : code === "invalid_order"
        ? "Conversation order was rejected."
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
      'button:not([disabled]), select:not([disabled]), textarea:not([disabled]), input:not([disabled]), summary, [href], [tabindex]:not([tabindex="-1"])'
    )].filter((element) => {
      if (element.closest("[hidden]")) return false
      const closedDisclosure = element.closest("details:not([open])")
      if (closedDisclosure && element !== closedDisclosure.querySelector("summary")) return false
      const style = window.getComputedStyle(element)
      return style.display !== "none" && style.visibility !== "hidden"
    })
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
