import { Controller } from "@hotwired/stimulus"

// Infinite scroll for the Target list. When the sentinel nears the viewport it
// fetches the next page (same filters/sort, carried in the URL) as an HTML
// fragment, appends the new rows before the sentinel, and advances to the page
// after that — stopping when the server sends an empty next-url. The column
// layout is re-applied by the targets-columns controller, which watches the
// body for new rows, so appended rows inherit the current widths/visibility.
export default class extends Controller {
  static targets = ["sentinel"]
  static values = { url: String }

  connect() {
    if (!this.urlValue) return
    this.loading = false
    this.observer = new IntersectionObserver(
      (entries) => entries.forEach((e) => e.isIntersecting && this.loadNext()),
      { rootMargin: "600px 0px" }
    )
    if (this.hasSentinelTarget) this.observer.observe(this.sentinelTarget)
  }

  disconnect() {
    if (this.observer) this.observer.disconnect()
  }

  async loadNext() {
    if (this.loading || !this.urlValue) return
    this.loading = true

    try {
      const res = await fetch(this.urlValue, {
        headers: { "X-Requested-With": "XMLHttpRequest", "Accept": "text/html" },
        credentials: "same-origin"
      })
      if (!res.ok) throw new Error(`HTTP ${res.status}`)

      const tpl = document.createElement("template")
      tpl.innerHTML = (await res.text()).trim()
      const rows = tpl.content.querySelectorAll("[data-target-row]")
      const nextUrl = tpl.content.querySelector("[data-next-url]")?.dataset.nextUrl || ""

      const parent = this.sentinelTarget.parentNode
      rows.forEach((row) => parent.insertBefore(row, this.sentinelTarget))

      if (nextUrl) {
        this.urlValue = nextUrl
        this.loading = false
      } else {
        this.observer.disconnect()
        this.sentinelTarget.remove()
      }
    } catch (err) {
      console.warn("targets infinite-scroll: fetch failed", err)
      this.loading = false
    }
  }
}
