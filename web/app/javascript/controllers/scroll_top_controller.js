import { Controller } from "@hotwired/stimulus"

// Floats a "jump to top" button into view once the user scrolls past the
// threshold; smooth-scrolls to the top on click. Fixed positioning means
// the button takes no layout space — the data-visible attr drives the
// fade/translate in CSS.
export default class extends Controller {
  static values = { threshold: { type: Number, default: 320 } }

  connect() {
    this.boundOnScroll = this.onScroll.bind(this)
    window.addEventListener("scroll", this.boundOnScroll, { passive: true })
    this.onScroll()
  }

  disconnect() {
    window.removeEventListener("scroll", this.boundOnScroll)
  }

  onScroll() {
    this.element.dataset.visible = window.scrollY > this.thresholdValue ? "true" : "false"
  }

  scrollTop(event) {
    event.preventDefault()
    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches
    window.scrollTo({ top: 0, behavior: reduce ? "auto" : "smooth" })
  }
}
