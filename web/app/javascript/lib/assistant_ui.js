const TERMINAL_TURN_STATUSES = new Set(["completed", "failed", "canceled", "interrupted"])
const CONTROL_CHARACTERS = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f]/g

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

export function safeDisplayText(value) {
  return String(value ?? "").replace(CONTROL_CHARACTERS, "�")
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
  missing_command_allowlist: "Assistant disabled: deployment configuration is incomplete.",
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

export function appendMessage(documentRef, container, message) {
  const article = documentRef.createElement("article")
  article.className = message.role === "user"
    ? "ml-auto max-w-[88%] rounded-2xl rounded-br-md border border-cyan-200 bg-cyan-50 px-4 py-3 text-sm leading-6 text-zinc-800 shadow-sm dark:border-cyan-400/15 dark:bg-cyan-400/10 dark:text-zinc-100"
    : "mr-auto max-w-[94%] rounded-2xl rounded-bl-md border border-zinc-200 bg-white px-4 py-3 text-sm leading-6 text-zinc-800 shadow-sm dark:border-white/10 dark:bg-zinc-900/80 dark:text-zinc-100"
  const label = documentRef.createElement("p")
  label.className = message.role === "user"
    ? "mb-1 text-[10px] font-semibold uppercase tracking-wider text-cyan-700/70 dark:text-cyan-300/60"
    : "mb-1 text-[10px] font-semibold uppercase tracking-wider text-zinc-500"
  label.textContent = message.role === "user" ? "You" : "Hunter assistant"
  const body = documentRef.createElement(message.role === "assistant" ? "pre" : "p")
  body.className = "whitespace-pre-wrap break-words font-sans [overflow-wrap:anywhere]"
  body.textContent = safeDisplayText(message.body)
  article.append(label, body)
  container.appendChild(article)
  return article
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
    const button = documentRef.createElement("button")
    button.type = "button"
    button.dataset.conversationId = String(conversation.id)
    button.className = active
      ? "assistant-conversation-active w-full truncate rounded-lg border border-cyan-400/20 bg-cyan-400/10 px-2.5 py-2 text-left text-xs font-medium text-cyan-100"
      : "w-full truncate rounded-lg border border-transparent px-2.5 py-2 text-left text-xs text-zinc-400 transition hover:border-white/10 hover:bg-white/5 hover:text-zinc-100"
    button.textContent = safeDisplayText(conversation.title)
    button.title = safeDisplayText(conversation.title)
    if (active) button.setAttribute("aria-current", "true")
    button.addEventListener("click", (event) => options.onSelect?.(conversation, event))
    container.appendChild(button)
  }
}

export function appendContextDisclosure(documentRef, container, context, onRemove) {
  const card = documentRef.createElement("article")
  card.className = "rounded-xl border border-cyan-200 bg-cyan-50/70 p-3 text-xs shadow-sm dark:border-cyan-400/15 dark:bg-cyan-400/[0.07]"
  const label = documentRef.createElement("p")
  label.className = "font-semibold text-cyan-900 dark:text-cyan-200"
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
  button.className = "mr-2 mt-3 rounded-lg border border-zinc-300 bg-white px-2.5 py-1.5 text-xs font-semibold text-zinc-700 transition hover:border-zinc-400 hover:bg-zinc-100 focus:outline-none focus:ring-2 focus:ring-cyan-500 dark:border-white/10 dark:bg-zinc-800 dark:text-zinc-200 dark:hover:bg-zinc-700"
  button.textContent = label
  button.addEventListener("click", callback)
  return button
}
