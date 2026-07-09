import { Controller } from "@hotwired/stimulus"

// Sidebar lock toggle. Hover expansion is CSS-only.
// Lock state persists in localStorage and is mirrored as data-locked on the
// aside and main targets (CSS-driven width and content padding).
export default class extends Controller {
  static targets = ["aside", "main"]
  static values = { locked: { type: Boolean, default: false } }

  connect() {
    const stored = localStorage.getItem("scope-ui:sidebar-locked")
    if (stored !== null) this.lockedValue = stored === "true"
    this.sync()
  }

  toggle() {
    this.lockedValue = !this.lockedValue
    localStorage.setItem("scope-ui:sidebar-locked", this.lockedValue)
    this.sync()
  }

  sync() {
    const v = this.lockedValue ? "true" : "false"
    if (this.hasAsideTarget) this.asideTarget.dataset.locked = v
    if (this.hasMainTarget)  this.mainTarget.dataset.locked  = v
  }
}
