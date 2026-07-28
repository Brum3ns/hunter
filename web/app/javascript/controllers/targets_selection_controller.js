import { Controller } from "@hotwired/stimulus"

// Tracks a target selection on a list page and hands it to Control Center.
// Two modes: explicit ids, or "all matching the current filter" (with a set of
// un-ticked exclude ids). `source` and the current query come from data attrs
// so the same controller serves the Target page (source=targets) and the
// Sitemap page (source=sitemap).
export default class extends Controller {
  static targets = ["checkbox", "count", "selectAll"]
  static values = { source: String, query: String }

  connect() {
    this.ids = new Set()
    this.excluded = new Set()
    this.allMatching = false
    this.render()
  }

  toggleRow(event) {
    const id = event.target.dataset.id
    if (this.allMatching) {
      event.target.checked ? this.excluded.delete(id) : this.excluded.add(id)
    } else {
      event.target.checked ? this.ids.add(id) : this.ids.delete(id)
    }
    this.render()
  }

  selectAllMatching() {
    this.allMatching = true
    this.excluded.clear()
    this.checkboxTargets.forEach((c) => (c.checked = true))
    this.render()
  }

  clear() {
    this.allMatching = false
    this.ids.clear()
    this.excluded.clear()
    this.checkboxTargets.forEach((c) => (c.checked = false))
    this.render()
  }

  descriptor() {
    if (this.allMatching) {
      return { source: this.sourceValue, mode: "filter", q: this.queryValue,
               exclude_ids: [...this.excluded] }
    }
    return { source: this.sourceValue, mode: "ids", ids: [...this.ids] }
  }

  count() {
    if (this.allMatching) return `all matching − ${this.excluded.size}`
    return `${this.ids.size}`
  }

  sendToJob() {
    const payload = { selections: [this.descriptor()] }
    sessionStorage.setItem("hunter.jobSelection", JSON.stringify(payload))
    window.location.assign("/control_center")
  }

  render() {
    if (this.hasCountTarget) this.countTarget.textContent = this.count()
  }
}
