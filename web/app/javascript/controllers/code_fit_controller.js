import { Controller } from "@hotwired/stimulus"

const COOKIE = "vuln_code_fit"

function preferred() {
  return document.cookie.split("; ").includes(`${COOKIE}=1`)
}

function remember(on) {
  document.cookie = `${COOKIE}=${on ? 1 : 0}; path=/; max-age=31536000; samesite=lax`
}

// Toggles a code block between horizontal-scroll and wrapped ("fit window")
// layout. The choice is stored in a cookie so every code block — including ones
// in a freshly reopened drawer — honors the last preference.
export default class extends Controller {
  static targets = ["pre", "label"]

  connect() {
    if (preferred()) this.apply(true)
  }

  toggle() {
    const fitted = !this.preTarget.classList.contains("code-fit")
    this.apply(fitted)
    remember(fitted)
  }

  apply(on) {
    this.preTarget.classList.toggle("code-fit", on)
    if (this.hasLabelTarget) this.labelTarget.textContent = on ? "Scroll" : "Fit window"
    this.element.setAttribute("data-fitted", on ? "true" : "false")
  }
}
