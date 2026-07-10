import { Controller } from "@hotwired/stimulus"

// Swaps the <img> src to a fallback when the original fails to load.
// Detaches after one swap so a broken fallback can't loop.
export default class extends Controller {
  static values = { src: String }

  connect() {
    this.boundOnError = this.onError.bind(this)
    this.element.addEventListener("error", this.boundOnError)
    // Catch images that already errored before connect (cached failures).
    if (this.element.complete && this.element.naturalWidth === 0) {
      this.onError()
    }
  }

  disconnect() {
    this.element.removeEventListener("error", this.boundOnError)
  }

  onError() {
    this.element.removeEventListener("error", this.boundOnError)
    if (this.hasSrcValue && this.element.src !== this.srcValue) {
      this.element.src = this.srcValue
    }
  }
}
