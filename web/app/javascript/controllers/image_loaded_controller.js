import { Controller } from "@hotwired/stimulus"

// Wraps an <img> with a sibling `.skeleton` placeholder. Adds `img-loaded`
// to the controller's element when the image resolves, so the skeleton can
// fade out via CSS. Also detects images that finished before connect
// (cached hits) so they don't sit behind a permanent shimmer.
export default class extends Controller {
  static targets = ["img"]

  connect() {
    const img = this.imgTarget
    if (img.complete && img.naturalWidth > 0) {
      this.element.classList.add("img-loaded")
      return
    }
    this.boundLoad = () => this.element.classList.add("img-loaded")
    img.addEventListener("load", this.boundLoad, { once: true })
  }

  disconnect() {
    if (this.boundLoad) this.imgTarget.removeEventListener("load", this.boundLoad)
  }
}
