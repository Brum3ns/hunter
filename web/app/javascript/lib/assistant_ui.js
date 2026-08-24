import {
  renderMarkdownFragment,
  safeDisplayText,
} from "#assistant-markdown"
import { decorateCodeBlocks } from "lib/assistant_code_blocks"

const TERMINAL_TURN_STATUSES = new Set(["completed", "failed", "canceled", "interrupted"])

export { safeDisplayText }

export class LatestRequest {
  constructor() { this.generation = 0 }
  issue() { this.generation += 1; return this.generation }
  invalidate() { this.generation += 1 }
  current(token) { return token === this.generation }
}

export function terminalTurnStatus(status) {
  return TERMINAL_TURN_STATUSES.has(String(status))
}

export function pollingDelay({ panelOpen, failureCount = 0 }) {
  if (panelOpen) return 750
  return Math.min(3000 * (2 ** Math.max(0, failureCount)), 30000)
}

export function composerSubmitIntent(event) {
  return event.key === "Enter" &&
    event.shiftKey !== true &&
    event.altKey !== true &&
    event.ctrlKey !== true &&
    event.metaKey !== true &&
    event.isComposing !== true
}

// The server sends a reason code only, never prose — see disabled_reason_for
// in Api::V1::Assistant::BaseController. Looking the code up in this frozen
// map (instead of interpolating the server string into the DOM) means an
// unrecognised or adversarial code can only ever fall back to the generic
// line below, never render as markup.
export const DISABLED_COPY = Object.freeze({
  no_provider_credentials: "Assistant disabled: no provider credentials are installed.",
  disabled_by_environment: "Assistant disabled by deployment configuration.",
  disabled_by_administrator: "Assistant disabled by an administrator.",
  missing_admin_username: "Assistant disabled: deployment configuration is incomplete.",
  missing_ansible_module_allowlist: "Assistant disabled: deployment configuration is incomplete.",
  invalid_retention_window: "Assistant disabled: retention configuration is invalid.",
})

export function renderDisabledNotice(noticeElement, composerElement, reason) {
  noticeElement.textContent = DISABLED_COPY[reason] || "Assistant disabled."
  composerElement.disabled = true
}

// Rendering a conversation re-decides whether the composer accepts input, so it must
// consult the same effective-enabled state the disabled notice does. Anything other
// than an explicit true leaves the composer disabled, so a conversation created before
// the assistant was disabled cannot present a typeable box the server would only refuse.
export function applyComposerAvailability(composerElement, sendElement, effectiveEnabled) {
  const disabled = effectiveEnabled !== true
  composerElement.disabled = disabled
  sendElement.disabled = disabled
  return !disabled
}

export function saveConfirmationText(draft) {
  const destination = draft.destination
    ? `${draft.destination.type} #${draft.destination.id} at version ${draft.destination.lock_version}`
    : `new ${draft.artifact_type}`
  const reviewedEffect = draft.diff || draft.content
  const reviewedLabel = draft.diff ? "Complete reviewed diff" : "Complete reviewed content"
  return [
    `Save “${safeDisplayText(draft.name)}”?`,
    `Destination: ${safeDisplayText(destination)}`,
    `Validation: ${safeDisplayText(draft.validation?.status)} · ${safeDisplayText(draft.validation?.version)}`,
    "Consequence: this saves the reviewed Control Center artifact. It does not run, send, schedule, or execute anything.",
    `${reviewedLabel}:`,
    safeDisplayText(reviewedEffect),
  ].join("\n\n")
}

export function conversationDeletionText(conversation) {
  return [
    `Delete “${safeDisplayText(conversation?.title || "Untitled conversation")}”?`,
    "Hunter will permanently delete this local conversation and its messages. " +
      "Provider or backup copies may remain under their retention policies.",
  ].join("\n\n")
}

export function appendMessage(documentRef, container, message, callbacks = {}) {
  const userMessage = message.role === "user"
  const assistantLabel = callbacks.assistantIdentity?.label || "Archived assistant"
  const assistantAssetUrl = callbacks.assistantIdentity?.assetUrl || null
  const row = documentRef.createElement("div")
  row.className = userMessage
    ? "assistant-message-row flex items-start justify-end gap-2.5"
    : "assistant-message-row flex items-start gap-2.5"

  const avatar = documentRef.createElement("span")
  avatar.dataset.avatarRole = userMessage ? "user" : "assistant"
  avatar.className = userMessage
    ? "grid h-8 w-8 shrink-0 place-items-center rounded-full border border-zinc-400 bg-zinc-200 text-[10px] font-bold text-zinc-700 shadow-sm dark:border-zinc-600 dark:bg-zinc-800 dark:text-zinc-200"
    : "grid h-8 w-8 shrink-0 place-items-center rounded-full border border-zinc-700 bg-zinc-950 text-[11px] font-bold text-white shadow-sm dark:border-zinc-500 dark:bg-zinc-950 dark:text-white"
  avatar.setAttribute("aria-hidden", "true")
  if (userMessage) {
    avatar.textContent = "Y"
  } else if (assistantAssetUrl) {
    const image = documentRef.createElement("img")
    image.src = assistantAssetUrl
    image.alt = ""
    image.className = "h-5 w-5 object-contain"
    avatar.appendChild(image)
  } else {
    avatar.textContent = "A"
  }

  const article = documentRef.createElement("article")
  article.className = userMessage
    ? "min-w-0 max-w-[88%] rounded-2xl rounded-br-md border border-zinc-400 bg-zinc-200/80 px-3.5 py-3 text-zinc-900 shadow-sm dark:border-zinc-600 dark:bg-zinc-800 dark:text-zinc-100"
    : "min-w-0 max-w-[94%] rounded-2xl rounded-bl-md border border-zinc-300 bg-white px-3.5 py-3 text-zinc-900 shadow-sm dark:border-zinc-600 dark:bg-zinc-900 dark:text-zinc-100"

  const heading = documentRef.createElement("div")
  heading.className = "mb-1.5 flex items-center justify-between gap-3"
  const label = documentRef.createElement("p")
  label.className = "text-[10px] font-semibold uppercase tracking-wider text-zinc-600 dark:text-zinc-400"
  label.textContent = userMessage ? "You" : assistantLabel
  const copy = documentRef.createElement("button")
  copy.type = "button"
  copy.className = "shrink-0 rounded-md border border-transparent px-1.5 py-0.5 text-[10px] font-semibold text-zinc-500 transition hover:border-zinc-300 hover:bg-zinc-100 hover:text-zinc-950 focus:outline-none focus:ring-2 focus:ring-zinc-500 dark:text-zinc-400 dark:hover:border-zinc-600 dark:hover:bg-zinc-800 dark:hover:text-white"
  copy.setAttribute("aria-label", `Copy ${userMessage ? "your" : assistantLabel} message`)
  copy.textContent = "Copy"
  copy.addEventListener("click", () => callbacks.onCopy?.(message))
  heading.append(label, copy)

  const body = documentRef.createElement("div")
  body.className = "assistant-markdown min-w-0 break-words [overflow-wrap:anywhere]"
  body.appendChild(renderMarkdownFragment(documentRef, message.body))
  decorateCodeBlocks(documentRef, body, { onCopy: callbacks.onCopyCode })
  article.append(heading, body)

  if (userMessage) {
    row.append(article, avatar)
  } else {
    row.append(avatar, article)
  }
  container.appendChild(row)
  return row
}

export function scrollMessageLog(container) {
  container.scrollTop = container.scrollHeight
}

export function renderConversationList(documentRef, container, conversations, options = {}) {
  container.replaceChildren()
  if (conversations.length === 0) {
    const empty = documentRef.createElement("p")
    empty.className = "px-2 py-4 text-center text-xs leading-5 text-zinc-500 dark:text-zinc-500"
    empty.textContent = "No conversations yet"
    container.appendChild(empty)
    return
  }

  for (const conversation of conversations) {
    const active = String(conversation.id) === String(options.currentId ?? "")
    const title = safeDisplayText(conversation.title)
    const row = documentRef.createElement("div")
    row.dataset.conversationId = String(conversation.id)
    row.draggable = true
    row.setAttribute("draggable", "true")
    row.className = active
      ? "assistant-conversation-active group flex items-center rounded-lg border border-zinc-600 bg-zinc-800 text-white shadow-sm"
      : "group flex items-center rounded-lg border border-transparent text-zinc-400 transition hover:border-zinc-700 hover:bg-zinc-900 hover:text-white"

    const button = documentRef.createElement("button")
    button.type = "button"
    button.dataset.conversationId = String(conversation.id)
    button.className = "min-w-0 flex-1 truncate px-2.5 py-2 text-left text-xs font-medium focus:outline-none focus:ring-2 focus:ring-inset focus:ring-zinc-400"
    button.textContent = title
    button.title = title
    if (active) button.setAttribute("aria-current", "true")
    button.addEventListener("click", (event) => options.onSelect?.(conversation, event))
    button.addEventListener("contextmenu", (event) => {
      event.preventDefault()
      options.onContextMenu?.(conversation, event, button)
    })
    button.addEventListener("keydown", (event) => {
      const menuIntent = event.key === "ContextMenu" || (event.key === "F10" && event.shiftKey)
      if (!menuIntent) return
      event.preventDefault()
      options.onMenu?.(conversation, event, button)
    })

    const menu = documentRef.createElement("button")
    menu.type = "button"
    menu.className = "mr-1 grid h-7 w-7 shrink-0 place-items-center rounded-md text-sm text-zinc-500 opacity-100 transition hover:bg-zinc-700 hover:text-white focus:opacity-100 focus:outline-none focus:ring-2 focus:ring-zinc-400 sm:opacity-0 sm:group-hover:opacity-100"
    menu.setAttribute("aria-haspopup", "menu")
    menu.setAttribute("aria-expanded", "false")
    menu.setAttribute("aria-label", `Actions for ${title}`)
    menu.textContent = "⋮"
    menu.addEventListener("click", (event) => options.onMenu?.(conversation, event, menu))

    row.addEventListener("dragstart", (event) => options.onDragStart?.(conversation, event, row))
    row.addEventListener("dragover", (event) => options.onDragOver?.(conversation, event, row))
    row.addEventListener("drop", (event) => options.onDrop?.(conversation, event, row))
    row.addEventListener("dragend", (event) => options.onDragEnd?.(conversation, event, row))
    row.append(button, menu)
    container.appendChild(row)
  }
}

export function appendContextDisclosure(documentRef, container, context, onRemove) {
  const card = documentRef.createElement("article")
  card.className = "rounded-xl border border-zinc-300 bg-zinc-100 p-3 text-xs shadow-sm dark:border-zinc-600 dark:bg-zinc-900"
  const label = documentRef.createElement("p")
  label.className = "font-semibold text-zinc-900 dark:text-zinc-100"
  label.textContent = `${safeDisplayText(context.type)} · ${safeDisplayText(context.label || context.id)}`
  const preview = documentRef.createElement("pre")
  preview.className = "slim-scroll mt-2 max-h-32 overflow-auto whitespace-pre-wrap break-words rounded-lg bg-white/70 p-2 font-mono text-[11px] leading-5 text-zinc-700 dark:bg-black/20 dark:text-zinc-300"
  preview.textContent = safeDisplayText(JSON.stringify(context.preview, null, 2))
  const remove = actionButton(documentRef, "Remove", () => onRemove?.(context))
  card.append(label, preview, remove)
  container.appendChild(card)
  return card
}

export function appendDraftCard(documentRef, container, draft, callbacks = {}) {
  const card = documentRef.createElement("article")
  card.className = "rounded-xl border border-zinc-200 bg-zinc-50 p-3 text-sm shadow-sm dark:border-white/10 dark:bg-zinc-900"

  const heading = documentRef.createElement("h3")
  heading.className = "font-semibold text-zinc-900 dark:text-zinc-100"
  heading.textContent = safeDisplayText(draft.name)
  card.appendChild(heading)

  const type = documentRef.createElement("p")
  type.className = "mt-1 text-xs text-zinc-500 dark:text-zinc-400"
  type.textContent = safeDisplayText(draft.artifact_type)
  card.appendChild(type)

  const source = documentRef.createElement("pre")
  source.className = "slim-scroll mt-3 max-h-64 overflow-auto whitespace-pre-wrap rounded-lg bg-zinc-950 p-3 font-mono text-xs leading-5 text-zinc-100 ring-1 ring-white/10"
  source.textContent = safeDisplayText(draft.content)
  card.appendChild(source)

  const validation = documentRef.createElement("p")
  validation.className = "mt-2 text-xs"
  validation.textContent = `Validation: ${safeDisplayText(draft.validation?.status)} · ${safeDisplayText(draft.validation?.version)}`
  card.appendChild(validation)

  for (const message of draft.validation?.messages || []) {
    const row = documentRef.createElement("p")
    row.className = "mt-1 text-xs text-rose-600 dark:text-rose-300"
    row.textContent = safeDisplayText(message)
    card.appendChild(row)
  }

  if (draft.diff) {
    const diff = documentRef.createElement("pre")
    diff.className = "slim-scroll mt-3 max-h-48 overflow-auto whitespace-pre-wrap rounded-lg bg-white p-2 font-mono text-xs leading-5 ring-1 ring-zinc-200 dark:bg-black/20 dark:ring-white/10"
    diff.textContent = safeDisplayText(draft.diff)
    card.appendChild(diff)
  }

  card.appendChild(actionButton(documentRef, "Copy", () => callbacks.onCopy?.(draft)))
  card.appendChild(actionButton(documentRef, "Open editor", () => callbacks.onOpenEditor?.(draft)))
  if (draft.can_save === true) {
    card.appendChild(actionButton(documentRef, "Save draft", () => callbacks.onSave?.(draft)))
  }

  container.appendChild(card)
  return card
}

function actionButton(documentRef, label, callback) {
  const button = documentRef.createElement("button")
  button.type = "button"
  button.className = "mr-2 mt-3 rounded-lg border border-zinc-300 bg-white px-2.5 py-1.5 text-xs font-semibold text-zinc-700 transition hover:border-zinc-500 hover:bg-zinc-100 focus:outline-none focus:ring-2 focus:ring-zinc-500 dark:border-zinc-600 dark:bg-zinc-800 dark:text-zinc-200 dark:hover:bg-zinc-700"
  button.textContent = label
  button.addEventListener("click", callback)
  return button
}
