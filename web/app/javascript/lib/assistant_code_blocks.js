const LANGUAGE_PATTERN = /^[a-z0-9_+.#-]{1,24}$/i
const COMPACT_LINE_THRESHOLD = 12
const LANGUAGE_MARKER = "language:"

export function normalizeCodeLanguage(value) {
  const language = String(value ?? "")
  return LANGUAGE_PATTERN.test(language) ? language : "Code"
}

export function decorateCodeBlocks(documentRef, root, { onCopy } = {}) {
  const blocks = []

  for (const code of root.querySelectorAll("pre > code")) {
    const pre = code.parentElement
    const existing = pre.parentElement
    if (existing?.classList.contains("assistant-code-block")) {
      blocks.push(existing)
      continue
    }

    const language = consumeLanguageMarker(code)
    if (language === null) continue

    const block = documentRef.createElement("div")
    block.className = "assistant-code-block"
    block.dataset.compact = String(logicalLineCount(code.textContent) > COMPACT_LINE_THRESHOLD)

    const toolbar = documentRef.createElement("div")
    toolbar.className = "assistant-code-toolbar"

    const label = documentRef.createElement("span")
    label.className = "assistant-code-language"
    label.textContent = language

    const compact = documentRef.createElement("button")
    compact.type = "button"
    compact.dataset.codeAction = "compact"
    compact.addEventListener("click", () => {
      block.dataset.compact = String(block.dataset.compact !== "true")
      applyCompactButtonState(compact, block.dataset.compact === "true")
    })
    applyCompactButtonState(compact, block.dataset.compact === "true")

    const copy = documentRef.createElement("button")
    copy.type = "button"
    copy.dataset.codeAction = "copy"
    copy.textContent = "Copy code"
    copy.addEventListener("click", () => onCopy?.(code.textContent ?? ""))

    toolbar.append(label, compact, copy)
    pre.before(block)
    block.append(toolbar, pre)
    blocks.push(block)
  }

  return blocks
}

function consumeLanguageMarker(code) {
  const marker = code.getAttribute("title")
  if (!marker?.startsWith(LANGUAGE_MARKER)) return null
  code.removeAttribute("title")
  return normalizeCodeLanguage(marker.slice(LANGUAGE_MARKER.length))
}

function logicalLineCount(value) {
  const lines = String(value ?? "").replace(/\r\n?/g, "\n").split("\n")
  if (lines.at(-1) === "") lines.pop()
  return lines.length
}

function applyCompactButtonState(button, compact) {
  button.textContent = compact ? "Expand" : "Compact"
  button.setAttribute("aria-expanded", String(!compact))
}
