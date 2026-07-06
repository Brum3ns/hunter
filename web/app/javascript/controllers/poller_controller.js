import { Controller } from "@hotwired/stimulus"

// Polls a job endpoint on an interval and applies the returned Turbo Stream,
// which replaces the whole result frame. When the job reaches a terminal state
// the replacement markup omits this controller, so it disconnects and polling
// stops — and because each update replaces the entire frame, no stale `src`
// lingers to re-fetch and wipe the final result.
export default class extends Controller {
  static values = { url: String, interval: { type: Number, default: 1500 } }

  connect() {
    if (!this.hasUrlValue) return

    this.timer = setInterval(() => this.poll(), this.intervalValue)
  }

  disconnect() {
    if (this.timer) clearInterval(this.timer)
  }

  async poll() {
    try {
      const response = await fetch(this.urlValue, {
        headers: { Accept: "text/vnd.turbo-stream.html" }
      })
      if (!response.ok) return

      window.Turbo.renderStreamMessage(await response.text())
    } catch (_error) {
      // Transient network error — the next tick will retry.
    }
  }
}
