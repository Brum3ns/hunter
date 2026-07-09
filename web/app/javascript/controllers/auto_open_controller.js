import { Controller } from "@hotwired/stimulus"

// Mount on a wrapper that contains a single modal partial. On connect,
// finds the inner <dialog data-modal-target="dialog"> and opens it via
// the native showModal() API. Used by the history dropdown's ?focus=<sid>
// flow: the server pre-renders the focused program's modal at the top of
// the page, and this controller pops it open immediately.
//
// Also strips ?focus= from the URL via history.replaceState so the modal
// doesn't re-open on every soft navigation (Turbo replace) or page reload.
export default class extends Controller {
  connect() {
    const dlg = this.element.querySelector("dialog[data-modal-target='dialog']")
    if (!dlg || dlg.open) return

    // Lock body scroll the same way modal_controller does, so the page
    // doesn't jump while the focused modal is open.
    this._savedY = window.scrollY || 0
    document.body.style.position = "fixed"
    document.body.style.top = `-${this._savedY}px`
    document.body.style.left = "0"
    document.body.style.right = "0"
    document.body.style.width = "100%"

    dlg.addEventListener("close", () => this._restore(), { once: true })
    dlg.showModal()

    this._stripFocusParam()
  }

  _restore() {
    document.body.style.position = ""
    document.body.style.top = ""
    document.body.style.left = ""
    document.body.style.right = ""
    document.body.style.width = ""
    window.scrollTo(0, this._savedY || 0)
  }

  _stripFocusParam() {
    try {
      const url = new URL(window.location.href)
      if (!url.searchParams.has("focus")) return
      url.searchParams.delete("focus")
      window.history.replaceState({}, "", url.pathname + (url.search ? url.search : "") + url.hash)
    } catch (_) { /* no-op */ }
  }
}
