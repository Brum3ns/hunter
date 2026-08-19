import { Controller } from "@hotwired/stimulus"
import { renderCveMarkdownFragment } from "lib/cve_markdown"

// Converts the Rails-escaped CVE details source into a sanitized DOM fragment.
// The source stays inert plain text when parsing or sanitization is unavailable.
export default class extends Controller {
  connect() {
    if (this.element.dataset.cveMarkdownRendered === "true") return

    const rendered = renderCveMarkdownFragment(document, this.element.textContent)
    this.element.replaceChildren(rendered)

    if (rendered.nodeType === 11) {
      this.element.classList.remove("whitespace-pre-wrap")
      this.element.dataset.cveMarkdownRendered = "true"
    }
  }
}
