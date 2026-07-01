import { Controller } from "@hotwired/stimulus"

// Reloads its host <turbo-frame> on an interval until the frame stops carrying
// this controller (terminal state). Cleans up its timer on disconnect.
export default class extends Controller {
  static values = { interval: { type: Number, default: 1500 } }

  connect() {
    this.timer = setInterval(() => {
      if (this.element.tagName === "TURBO-FRAME") this.element.reload()
    }, this.intervalValue)
  }

  disconnect() {
    if (this.timer) clearInterval(this.timer)
  }
}
