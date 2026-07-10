import { Controller } from "@hotwired/stimulus"
import hljs from "highlight.js"
import http from "highlight.js/http"
import bash from "highlight.js/bash"
import javascript from "highlight.js/javascript"
import xml from "highlight.js/xml"
import json from "highlight.js/json"
import css from "highlight.js/css"

let registered = false

function register() {
  if (registered) return
  hljs.registerLanguage("http", http)
  hljs.registerLanguage("bash", bash)
  hljs.registerLanguage("javascript", javascript)
  hljs.registerLanguage("xml", xml)
  hljs.registerLanguage("json", json)
  hljs.registerLanguage("css", css)
  registered = true
}

// Content-Type MIME -> hljs language. Anchored, no unbounded backtracking:
// each pattern is linear over untrusted input.
const MIME_LANGUAGE = [
  [/^text\/html\b/, "xml"],
  [/^application\/xhtml\+xml\b/, "xml"],
  [/^(?:application|text)\/(?:[a-z0-9.+-]*\+)?xml\b/, "xml"],
  [/^(?:application|text)\/(?:java|ecma)script\b/, "javascript"],
  [/^application\/x-javascript\b/, "javascript"],
  [/^(?:application|text)\/(?:[a-z0-9.+-]*\+)?json\b/, "json"],
  [/^text\/css\b/, "css"]
]

function bodyLanguage(headers) {
  const match = headers.match(/^content-type:[ \t]*([^\r\n;]+)/im)
  if (!match) return null
  const mime = match[1].trim().toLowerCase()
  for (const [pattern, language] of MIME_LANGUAGE) {
    if (pattern.test(mime)) return language
  }
  return null
}

function highlight(source, language) {
  return hljs.highlight(source, { language, ignoreIllegals: true }).value
}

// Highlights the associated <code> block once, on connect. When bodyMime is set
// the block is treated as a full HTTP message: the status line + headers are
// highlighted as `http`, and the body is highlighted by its Content-Type MIME.
// The raw text is never altered — only wrapped in coloring spans, so the visible
// content is byte-for-byte identical to the source.
export default class extends Controller {
  static values = { language: String, bodyMime: Boolean }

  connect() {
    register()
    const code = this.element

    if (this.bodyMimeValue) {
      code.innerHTML = this.highlightMessage(code.textContent)
    } else if (this.languageValue && hljs.getLanguage(this.languageValue)) {
      code.innerHTML = highlight(code.textContent, this.languageValue)
    } else {
      hljs.highlightElement(code)
    }
    code.classList.add("hljs")
  }

  highlightMessage(source) {
    const separator = source.match(/\r?\n\r?\n/)
    if (!separator) return highlight(source, "http")

    const boundary = separator.index + separator[0].length
    const head = source.slice(0, boundary)
    const body = source.slice(boundary)
    const headHtml = highlight(head, "http")
    if (body.length === 0) return headHtml

    const language = bodyLanguage(head)
    // `plaintext` still escapes HTML, so untrusted bodies stay inert.
    const bodyHtml = highlight(body, language && hljs.getLanguage(language) ? language : "plaintext")
    return headHtml + bodyHtml
  }
}
