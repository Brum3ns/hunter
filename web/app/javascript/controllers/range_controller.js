import { Controller } from "@hotwired/stimulus"

// Range slider with value display + filled track. Attach to the wrapper:
//   <div data-controller="range">
//     <span data-range-target="display"></span>
//     <input type="range" data-range-target="input"
//            data-range-format-value="money|hours|number" />
//   </div>
export default class extends Controller {
  static targets = ["input", "display"]

  connect() { this.update() }

  update() {
    const el  = this.inputTarget
    const min = +el.min
    const max = +el.max
    const v   = +el.value
    const pct = max > min ? ((v - min) / (max - min)) * 100 : 0
    el.style.setProperty("--val", `${pct}%`)

    if (this.hasDisplayTarget) {
      this.displayTarget.textContent = v === 0 ? "Any" : this.format(v)
    }
  }

  format(v) {
    switch (this.inputTarget.dataset.rangeFormatValue) {
      case "money": return "$" + v.toLocaleString()
      case "hours": return v + "h"
      default:      return v.toLocaleString()
    }
  }
}
