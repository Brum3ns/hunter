import { Controller } from "@hotwired/stimulus"

// Copies a value to the clipboard on click and raises a toast. Used on detail
// fields so any metadata value can be grabbed with a single tap.
export default class extends Controller {
  static values = { text: String, label: String }

  copy() {
    const text = this.hasTextValue ? this.textValue : this.element.textContent.trim()
    if (!text) return

    navigator.clipboard.writeText(text).then(() => {
      const what = this.hasLabelValue ? this.labelValue : "Value"
      window.dispatchEvent(new CustomEvent("toast", { detail: { message: `${what} copied` } }))
    })
  }
}
