import { Controller } from "@hotwired/stimulus"

// Right-side detail drawer. Animates the panel in from the right and fades the
// blurred backdrop in on connect; reverses both on close, then empties the
// Turbo Frame so the same row can reopen it. Closes on Escape or backdrop click.
export default class extends Controller {
  static targets = ["panel", "backdrop"]

  connect() {
    document.documentElement.classList.add("overflow-hidden")
    // Paint the off-screen state first, then transition in on the next frame.
    requestAnimationFrame(() => {
      this.panelTarget.classList.remove("translate-x-full")
      this.backdropTarget.classList.remove("opacity-0")
    })
  }

  close() {
    this.panelTarget.classList.add("translate-x-full")
    this.backdropTarget.classList.add("opacity-0")
    this.panelTarget.addEventListener("transitionend", () => this.teardown(), { once: true })
  }

  teardown() {
    const frame = this.element.closest("turbo-frame")
    if (frame) {
      frame.removeAttribute("src")
      frame.innerHTML = ""
    }
  }

  disconnect() {
    document.documentElement.classList.remove("overflow-hidden")
  }
}
