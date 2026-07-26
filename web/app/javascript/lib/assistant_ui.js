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
    ? "ml-8 rounded-lg bg-zinc-900 p-3 text-sm text-white dark:bg-zinc-100 dark:text-zinc-900"
    : "mr-8 rounded-lg bg-zinc-100 p-3 text-sm text-zinc-800 dark:bg-zinc-800 dark:text-zinc-100"
  const label = documentRef.createElement("p")
  label.className = "mb-1 text-xs font-semibold opacity-60"
  label.textContent = message.role === "user" ? "You" : "Hunter assistant"
  const body = documentRef.createElement(message.role === "assistant" ? "pre" : "p")
  body.className = "whitespace-pre-wrap break-words font-sans"
  body.textContent = safeDisplayText(message.body)
  article.append(label, body)
  container.appendChild(article)
  return article
}

export function appendContextDisclosure(documentRef, container, context, onRemove) {
  const card = documentRef.createElement("article")
  card.className = "rounded border border-cyan-200 bg-cyan-50 p-2 text-xs dark:border-cyan-800 dark:bg-cyan-950/30"
  const label = documentRef.createElement("p")
  label.className = "font-semibold text-cyan-900 dark:text-cyan-100"
  label.textContent = `${safeDisplayText(context.type)} · ${safeDisplayText(context.label || context.id)}`
  const preview = documentRef.createElement("pre")
  preview.className = "mt-1 max-h-32 overflow-auto whitespace-pre-wrap break-words"
  preview.textContent = safeDisplayText(JSON.stringify(context.preview, null, 2))
  const remove = actionButton(documentRef, "Remove", () => onRemove?.(context))
  card.append(label, preview, remove)
  container.appendChild(card)
  return card
}

export function appendDraftCard(documentRef, container, draft, callbacks = {}) {
  const card = documentRef.createElement("article")
  card.className = "rounded-lg border border-zinc-200 bg-zinc-50 p-3 text-sm dark:border-zinc-700 dark:bg-zinc-900"

  const heading = documentRef.createElement("h3")
  heading.className = "font-semibold text-zinc-900 dark:text-zinc-100"
  heading.textContent = safeDisplayText(draft.name)
  card.appendChild(heading)

  const type = documentRef.createElement("p")
  type.className = "mt-1 text-xs text-zinc-500 dark:text-zinc-400"
  type.textContent = safeDisplayText(draft.artifact_type)
  card.appendChild(type)

  const source = documentRef.createElement("pre")
  source.className = "mt-3 max-h-64 overflow-auto whitespace-pre-wrap rounded bg-zinc-950 p-3 text-xs text-zinc-100"
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
    diff.className = "mt-3 max-h-48 overflow-auto whitespace-pre-wrap rounded bg-zinc-100 p-2 text-xs dark:bg-zinc-800"
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
  button.className = "mr-2 mt-3 rounded border border-zinc-300 px-2 py-1 text-xs font-medium dark:border-zinc-700"
  button.textContent = label
  button.addEventListener("click", callback)
  return button
}
