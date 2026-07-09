import { Controller } from "@hotwired/stimulus"

// Lazily loads the next page of programs when a sentinel scrolls into view.
//
// Two sentinels live in the DOM — one inside the cards grid, one inside the
// table tbody — because only the visible one has layout and will fire the
// IntersectionObserver. The XHR response contains both [data-program-card]
// and [data-program-row] elements; this controller routes each kind to its
// matching parent so both views stay populated regardless of which one was
// visible when the fetch fired. That way switching view modes is instant —
// no refetch needed.
//
// Flow:
//   1. Inject N skeleton cards before the cards sentinel (visual feedback;
//      only meaningful in card view — table view just shows nothing for the
//      brief fetch window).
//   2. Fetch the next-page URL with X-Requested-With.
//   3. Distribute cards into the cards parent, rows into the rows parent.
//   4. Swap the next URL (or remove the sentinels when done).
export default class extends Controller {
  static targets = ["cardSentinel", "rowSentinel", "skeleton"]
  static values  = {
    url:           String,
    skeletonCount: { type: Number, default: 6 }
  }

  connect() {
    if (!this.urlValue) return
    this.loading  = false
    this.observer = new IntersectionObserver(
      (entries) => entries.forEach((e) => e.isIntersecting && this.loadNext()),
      { rootMargin: "600px 0px" }
    )
    this.sentinels.forEach((s) => this.observer.observe(s))
  }

  disconnect() {
    if (this.observer) this.observer.disconnect()
  }

  get sentinels() {
    const list = []
    if (this.hasCardSentinelTarget) list.push(this.cardSentinelTarget)
    if (this.hasRowSentinelTarget)  list.push(this.rowSentinelTarget)
    return list
  }

  async loadNext() {
    if (this.loading || !this.urlValue) return
    this.loading = true

    const skeletons = this.injectSkeletons()

    try {
      const res = await fetch(this.urlValue, {
        headers: { "X-Requested-With": "XMLHttpRequest", "Accept": "text/html" },
        credentials: "same-origin"
      })
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
      const html = await res.text()

      const tpl = document.createElement("template")
      tpl.innerHTML = html.trim()

      const newCards = tpl.content.querySelectorAll("[data-program-card]")
      const newRows  = tpl.content.querySelectorAll("[data-program-row]")
      const marker   = tpl.content.querySelector("[data-next-url]")
      const nextUrl  = marker?.dataset.nextUrl || ""

      skeletons.forEach((el) => el.remove())

      if (this.hasCardSentinelTarget) {
        const parent = this.cardSentinelTarget.parentNode
        newCards.forEach((el) => parent.insertBefore(el, this.cardSentinelTarget))
      }
      if (this.hasRowSentinelTarget) {
        const parent = this.rowSentinelTarget.parentNode
        newRows.forEach((el) => parent.insertBefore(el, this.rowSentinelTarget))
      }

      if (nextUrl) {
        this.urlValue = nextUrl
        this.loading  = false
      } else {
        this.observer.disconnect()
        this.sentinels.forEach((s) => s.remove())
      }
    } catch (err) {
      console.warn("infinite-scroll: fetch failed", err)
      skeletons.forEach((el) => el.remove())
      this.loading = false
    }
  }

  injectSkeletons() {
    if (!this.hasSkeletonTarget || !this.hasCardSentinelTarget) return []
    const tpl = this.skeletonTarget
    const out = []
    for (let i = 0; i < this.skeletonCountValue; i++) {
      const node = tpl.content.firstElementChild.cloneNode(true)
      this.cardSentinelTarget.parentNode.insertBefore(node, this.cardSentinelTarget)
      out.push(node)
    }
    return out
  }
}
