import { Controller } from "@hotwired/stimulus"

// When a banner image fails to load, hide it (plus the dark vignette designed
// to darken the photo) and reveal the decorative fallback overlay below — so
// the card shows the platform-colored gradient instead of a broken-image icon.
// Also catches images that already errored before connect (cached failures).
export default class extends Controller {
  static targets = ["fallback", "image", "vignette"]

  connect() {
    if (!this.hasImageTarget) return
    const img = this.imageTarget.tagName === "IMG"
      ? this.imageTarget
      : this.imageTarget.querySelector("img")
    if (img && img.complete && img.naturalWidth === 0) {
      this.failed()
    }
  }

  failed() {
    if (this.hasImageTarget) this.imageTarget.classList.add("hidden")
    if (this.hasVignetteTarget) this.vignetteTarget.classList.add("hidden")
    if (this.hasFallbackTarget) this.fallbackTarget.classList.remove("hidden")
  }
}
