import { Controller } from "@hotwired/stimulus"
import { TargetSelection } from "lib/target_selection"

// DOM wrapper around lib/target_selection.js. Serves both the Target page
// (source=targets) and the Sitemap page (source=sitemap). Selection kinds:
// per-row checkboxes (with SHIFT-click range), whole-origin checkboxes
// (sitemap), and "select all matching filter". Hands the result to Control
// Center via sessionStorage.
export default class extends Controller {
  static targets = ["checkbox", "originCheckbox", "count"]
  static values = { source: String, query: String }

  connect() {
    this.selection = new TargetSelection({ source: this.sourceValue, query: this.queryValue })
    this.render()
  }

  // A per-row checkbox click. Supports SHIFT-click to select the range from the
  // last-clicked box to this one across the currently-rendered rows.
  toggleRow(event) {
    const box = event.target
    const boxes = this.checkboxTargets
    const index = boxes.indexOf(box)
    const orderedIds = boxes.map((c) => c.dataset.id)
    const { ids, checked } = this.selection.applyClick(orderedIds, index, box.checked, event.shiftKey)

    // Sync the DOM for every box the range touched (the clicked one is already
    // in `checked`; the rest need to be brought into line).
    const affected = new Set(ids)
    boxes.forEach((c) => {
      if (affected.has(c.dataset.id)) c.checked = checked
    })
    this.render()
  }

  toggleOrigin(event) {
    this.selection.toggleOrigin(event.target.dataset.origin, event.target.checked)
    this.render()
  }

  selectAllMatching() {
    this.selection.selectAllMatching()
    this.checkboxTargets.forEach((c) => (c.checked = true))
    this.originCheckboxTargets.forEach((c) => (c.checked = false))
    this.render()
  }

  clear() {
    this.selection.clear()
    this.checkboxTargets.forEach((c) => (c.checked = false))
    this.originCheckboxTargets.forEach((c) => (c.checked = false))
    this.render()
  }

  sendToJob() {
    const payload = { selections: this.selection.descriptors() }
    sessionStorage.setItem("hunter.jobSelection", JSON.stringify(payload))
    window.location.assign("/control_center")
  }

  render() {
    if (this.hasCountTarget) this.countTarget.textContent = this.selection.countLabel()
  }
}
