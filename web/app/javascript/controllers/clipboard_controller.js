import { Controller } from "@hotwired/stimulus"

// Copies a code block's text to the clipboard and briefly confirms on the button.
export default class extends Controller {
  static targets = ["source", "button"]

  copy() {
    navigator.clipboard.writeText(this.sourceTarget.innerText).then(() => {
      const label = this.buttonTarget
      const original = label.textContent
      label.textContent = "Copied"
      setTimeout(() => { label.textContent = original }, 1200)
    })
  }
}
