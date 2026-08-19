import DOMPurify from "dompurify"
import { Marked, Renderer } from "marked"

const CONTROL_CHARACTERS = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f]/g
const ALLOWED_TAGS = Object.freeze([
  "p", "br", "strong", "em", "del", "blockquote", "ul", "ol", "li",
  "pre", "code", "h1", "h2", "h3", "h4", "h5", "h6", "a", "hr",
  "table", "thead", "tbody", "tr", "th", "td",
])
const ALLOWED_ATTRIBUTES = Object.freeze(["href", "title"])

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;")
}

const renderer = new Renderer()
renderer.html = ({ text }) => escapeHtml(text)

const markdownParser = new Marked({
  async: false,
  breaks: true,
  gfm: true,
  renderer,
})

export function safeCveDisplayText(value) {
  return String(value ?? "").replace(CONTROL_CHARACTERS, "�")
}

export function renderCveMarkdownFragment(documentRef, body, options = {}) {
  const displayText = safeCveDisplayText(body)
  const parser = options.parser || markdownParser
  const purifier = options.purifier || DOMPurify

  try {
    if (purifier.isSupported !== true) return documentRef.createTextNode(displayText)

    const parsed = parser.parse(displayText)
    if (typeof parsed !== "string") throw new TypeError("Markdown parser must return a string")

    const fragment = purifier.sanitize(parsed, {
      ALLOWED_ATTR: ALLOWED_ATTRIBUTES,
      ALLOWED_TAGS,
      ALLOW_ARIA_ATTR: false,
      ALLOW_DATA_ATTR: false,
      RETURN_DOM_FRAGMENT: true,
      RETURN_TRUSTED_TYPE: false,
      SANITIZE_DOM: true,
      SANITIZE_NAMED_PROPS: true,
    })
    if (!fragment || fragment.nodeType !== 11) {
      throw new TypeError("Markdown sanitizer must return a DocumentFragment")
    }

    return fragment
  } catch {
    return documentRef.createTextNode(displayText)
  }
}
