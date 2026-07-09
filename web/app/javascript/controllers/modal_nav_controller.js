import { Controller } from "@hotwired/stimulus"

// Outline navigation for the program modal. Sections are matched via
// data-section attributes (not IDs) so multiple modals on one page can coexist
// without ID collisions. Clicks smooth-scroll the modal's inner scroll
// container; an IntersectionObserver tracks the active section as the user
// scrolls.
export default class extends Controller {
  static targets = ["link"]

  connect() {
    this._scope = this.element.closest("dialog")?.querySelector("[data-modal-scroll]")
    if (!this._scope) return

    this._sections = new Map()
    this.linkTargets.forEach(a => {
      const key = a.dataset.section
      const sec = this._scope.querySelector(`[data-section="${key}"]`)
      if (sec) this._sections.set(key, sec)
    })

    this._observer = new IntersectionObserver(this._onIntersect.bind(this), {
      root: this._scope,
      rootMargin: "0px 0px -70% 0px",
      threshold: 0
    })
    this._sections.forEach(sec => this._observer.observe(sec))
  }

  disconnect() {
    this._observer?.disconnect()
  }

  jump(event) {
    event.preventDefault()
    const key = event.currentTarget.dataset.section
    const target = this._sections?.get(key)
    if (!target || !this._scope) return
    this._setActive(key)
    this._suppressObserverUntilScrollEnd()
    const targetRect = target.getBoundingClientRect()
    const scopeRect = this._scope.getBoundingClientRect()
    const top = this._scope.scrollTop + (targetRect.top - scopeRect.top) - 8
    this._scope.scrollTo({ top: Math.max(0, top), behavior: "smooth" })
  }

  // While a programmatic smooth-scroll is in flight, the IntersectionObserver
  // fires for every section it crosses, which causes the active link to flicker
  // through intermediate sections before landing on the target. Suppress
  // observer-driven updates until the scroll settles.
  _suppressObserverUntilScrollEnd() {
    this._suppressed = true
    clearTimeout(this._suppressTimer)
    const release = () => {
      this._suppressed = false
      this._scope.removeEventListener("scrollend", release)
      clearTimeout(this._suppressTimer)
    }
    if ("onscrollend" in window) {
      this._scope.addEventListener("scrollend", release, { once: true })
    }
    this._suppressTimer = setTimeout(release, 900)
  }

  _onIntersect(entries) {
    if (this._suppressed) return
    const visible = entries.filter(e => e.isIntersecting)
    if (visible.length === 0) return
    const top = visible.reduce((a, b) =>
      a.boundingClientRect.top < b.boundingClientRect.top ? a : b
    )
    this._setActive(top.target.dataset.section)
  }

  _setActive(key) {
    this.linkTargets.forEach(a => {
      a.dataset.active = (a.dataset.section === key) ? "true" : "false"
    })
  }
}
