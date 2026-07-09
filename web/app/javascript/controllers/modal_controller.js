import { Controller } from "@hotwired/stimulus"

// Wraps a clickable trigger + a native <dialog> element.
// Opens on trigger click (ignores clicks on inner links/buttons so the
// external-link button on the card still works); closes on ESC, the close
// button, and backdrop clicks. While open, pins the body at its current
// scroll position so opening the modal can't shift the page to the top.
//
// The dialog target is set up with `dialogTargetConnected` / `Disconnected`
// rather than `connect` so the same controller works for two delivery
// modes:
//   * Server-rendered dialog already in the DOM at connect (programs
//     index cards/rows — dialog target appears immediately).
//   * Dialog fetched async and injected later (the /monitor page fetches
//     /programs/:sid/modal on row click and drops the HTML into a
//     pre-existing data-controller="modal" host). The target callback
//     fires whenever the dialog appears, so the close listener is wired
//     up either way.
export default class extends Controller {
  static targets = ["dialog"]

  dialogTargetConnected(dialog) {
    this._onClose = () => this._unlockScroll()
    dialog.addEventListener("close", this._onClose)
  }

  dialogTargetDisconnected(dialog) {
    if (this._onClose) dialog.removeEventListener("close", this._onClose)
    if (this._locked) this._unlockScroll()
  }

  disconnect() {
    if (this._locked) this._unlockScroll()
  }

  open(event) {
    if (event.target.closest("a, button")) return
    event.preventDefault()
    this._lockScroll()
    this.dialogTarget.showModal()
  }

  close() {
    this.dialogTarget.close()
  }

  backdropClose(event) {
    if (event.target === this.dialogTarget) this.dialogTarget.close()
  }

  _lockScroll() {
    if (this._locked) return
    this._locked = true
    this._savedY = window.scrollY || window.pageYOffset || 0
    const scrollbarW = window.innerWidth - document.documentElement.clientWidth
    const body = document.body
    body.style.position = "fixed"
    body.style.top = `-${this._savedY}px`
    body.style.left = "0"
    body.style.right = "0"
    body.style.width = "100%"
    if (scrollbarW > 0) body.style.paddingRight = `${scrollbarW}px`
  }

  _unlockScroll() {
    if (!this._locked) return
    this._locked = false
    const body = document.body
    body.style.position = ""
    body.style.top = ""
    body.style.left = ""
    body.style.right = ""
    body.style.width = ""
    body.style.paddingRight = ""
    window.scrollTo(0, this._savedY)
  }
}
