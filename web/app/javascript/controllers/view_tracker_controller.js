import { Controller } from "@hotwired/stimulus"

// Mount on the program modal's <dialog>:
//   data-controller="view-tracker"
//   data-view-tracker-sid-value="<%= program.sid %>"
//   data-view-tracker-dwell-value="15000"  (optional, default 15s)
//
// Starts a dwell timer the moment the dialog opens. If the user closes the
// modal before the timer elapses the view is discarded (skim). If they stay
// past the threshold we POST /programs/:sid/view once and stop tracking until
// the next open. Resilient to repeated open/close cycles in the same session.
export default class extends Controller {
  static values = {
    sid:   String,
    dwell: { type: Number, default: 15000 }
  }

  connect() {
    this._timer = null
    this._sent  = false

    // Native <dialog> fires `close` when the dialog is dismissed for any
    // reason (ESC, backdrop, .close() call). It does not fire an `open`
    // event, so we watch the `open` attribute via a MutationObserver.
    this._onClose = () => this._cancel()
    this.element.addEventListener("close", this._onClose)

    this._observer = new MutationObserver(records => {
      for (const r of records) {
        if (r.attributeName === "open") {
          this.element.hasAttribute("open") ? this._start() : this._cancel()
        }
      }
    })
    this._observer.observe(this.element, { attributes: true, attributeFilter: ["open"] })

    // The dialog might already be open at connect time (e.g. when the
    // auto-open controller fires before view-tracker mounts).
    if (this.element.hasAttribute("open")) this._start()
  }

  disconnect() {
    this.element.removeEventListener("close", this._onClose)
    this._observer?.disconnect()
    this._cancel()
  }

  _start() {
    if (this._sent || this._timer) return
    this._timer = setTimeout(() => this._track(), this.dwellValue)
  }

  _cancel() {
    if (this._timer) {
      clearTimeout(this._timer)
      this._timer = null
    }
  }

  _track() {
    this._timer = null
    if (this._sent) return
    this._sent = true

    fetch(`/programs/${this.sidValue}/view`, {
      method: "POST",
      headers: {
        "X-CSRF-Token": this._csrfToken(),
        "Accept": "application/json",
        "X-Requested-With": "XMLHttpRequest"
      },
      credentials: "same-origin"
    }).catch(err => {
      console.warn("view tracker failed", err)
      this._sent = false
    })
  }

  _csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.getAttribute("content") || ""
  }
}
