import { Controller } from "@hotwired/stimulus"

// Column-count slider for the programs card grid.
// Persists the chosen count in localStorage and writes it as the --cols
// custom property on the grid, plus the numeric display next to the slider.
export default class extends Controller {
  static targets = ["input", "display", "grid"]
  static values  = { storageKey: { type: String, default: "scope-ui:cols" } }

  connect() {
    const stored = parseInt(localStorage.getItem(this.storageKeyValue), 10)
    if (!Number.isNaN(stored) && this.hasInputTarget) {
      const clamped = Math.min(Math.max(stored, +this.inputTarget.min), +this.inputTarget.max)
      this.inputTarget.value = clamped
    }
    this.update()
  }

  update() {
    if (!this.hasInputTarget) return
    const v = +this.inputTarget.value
    if (this.hasGridTarget)    this.gridTarget.style.setProperty("--cols", v)
    if (this.hasDisplayTarget) this.displayTarget.textContent = v
    localStorage.setItem(this.storageKeyValue, v)

    const min = +this.inputTarget.min
    const max = +this.inputTarget.max
    const pct = max > min ? ((v - min) / (max - min)) * 100 : 0
    this.inputTarget.style.setProperty("--val", `${pct}%`)
  }
}
