import { Controller } from "@hotwired/stimulus"

// Collapses the vulnerabilities filter sidebar on desktop so the findings list
// (the main view) gets the full width. Toggling flips `lg:hidden` on the panel
// and remembers the choice in a cookie; the server reads that cookie to render
// the collapsed state on the next load, so there is no flash.
export default class extends Controller {
  static targets = ["panel"]

  toggle() {
    const hidden = this.panelTarget.classList.toggle("lg:hidden")
    const oneYear = 60 * 60 * 24 * 365
    document.cookie = `vuln_filters_hidden=${hidden ? "1" : "0"}; path=/; max-age=${oneYear}; SameSite=Lax`
  }
}
