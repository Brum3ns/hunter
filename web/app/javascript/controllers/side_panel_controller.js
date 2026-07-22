import { Controller } from "@hotwired/stimulus"

// Docked right-side detail panel for the Target list. Unlike the modal drawer,
// it does NOT lock body scroll or cover the list — on desktop it sits in the
// flex row so the list makes room beside it and stays clickable (click another
// row to swap the panel). On mobile it slides over as a full-width sheet with a
// tap-to-close backdrop. Slides in on connect; on close it slides out and
// empties the Turbo Frame so the same row can reopen it.
const WIDTH_KEY = "targets.panelWidth"
const MIN_WIDTH = 320

export default class extends Controller {
  static targets = ["panel", "backdrop"]

  connect() {
    this.applyStoredWidth()
    requestAnimationFrame(() => {
      this.panelTarget.classList.remove("translate-x-full")
      if (this.hasBackdropTarget) this.backdropTarget.classList.remove("opacity-0")
    })
  }

  // --- width persistence + drag-to-resize (desktop only) -----------------
  desktop() {
    return window.matchMedia("(min-width: 768px)").matches
  }

  maxWidth() {
    // Leave the list at least ~380px so it never collapses to nothing.
    return Math.max(MIN_WIDTH, window.innerWidth - 380)
  }

  applyStoredWidth() {
    if (!this.desktop()) return
    const saved = parseInt(localStorage.getItem(WIDTH_KEY), 10)
    if (saved) this.panelTarget.style.width = `${Math.min(this.maxWidth(), Math.max(MIN_WIDTH, saved))}px`
  }

  // Drag the left-edge handle to set the panel width. The panel is docked on
  // the right, so dragging left (smaller clientX) widens it.
  startResize(event) {
    event.preventDefault()
    const startX = event.clientX
    const startWidth = this.panelTarget.offsetWidth
    const prevSelect = document.body.style.userSelect
    document.body.style.userSelect = "none"
    document.body.style.cursor = "col-resize"

    const onMove = (e) => {
      const next = Math.min(this.maxWidth(), Math.max(MIN_WIDTH, startWidth + (startX - e.clientX)))
      this.panelTarget.style.width = `${next}px`
    }
    const onUp = () => {
      document.removeEventListener("mousemove", onMove)
      document.removeEventListener("mouseup", onUp)
      document.body.style.userSelect = prevSelect
      document.body.style.cursor = ""
      localStorage.setItem(WIDTH_KEY, String(this.panelTarget.offsetWidth))
    }
    document.addEventListener("mousemove", onMove)
    document.addEventListener("mouseup", onUp)
  }

  // Close when the click lands outside the panel — but not on a list row, so
  // clicking another asset swaps the panel instead of dismissing it.
  closeOutside(event) {
    if (this.panelTarget.contains(event.target)) return
    if (event.target.closest("[data-target-row]")) return
    this.close()
  }

  close() {
    if (this.closing) return
    this.closing = true
    this.panelTarget.classList.add("translate-x-full")
    if (this.hasBackdropTarget) this.backdropTarget.classList.add("opacity-0")
    this.panelTarget.addEventListener("transitionend", () => this.teardown(), { once: true })
  }

  teardown() {
    const frame = this.element.closest("turbo-frame")
    if (frame) {
      frame.removeAttribute("src")
      frame.innerHTML = ""
    }
  }
}
