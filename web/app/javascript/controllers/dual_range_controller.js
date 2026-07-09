import { Controller } from "@hotwired/stimulus"

// Dual-thumb range slider driving a min/max param pair. Overlapping
// <input type="range"> elements share a track; the controller clamps
// thumbs so lo ≤ hi, positions the colored fill bar, and blanks the
// input `name` when a thumb sits at its extreme (slider min for the
// lo thumb, slider max for the hi thumb) so the form never submits
// no-op filters.
export default class extends Controller {
  static targets = ["minInput", "maxInput", "fill", "display"]
  static values  = { format: { type: String, default: "number" } }

  connect() { this.update() }

  update(event) {
    const lo = this.minInputTarget
    const hi = this.maxInputTarget
    const min = +lo.min
    const max = +lo.max

    let v_lo = +lo.value
    let v_hi = +hi.value

    if (event && event.target === lo && v_lo > v_hi) v_hi = v_lo
    if (event && event.target === hi && v_hi < v_lo) v_lo = v_hi
    lo.value = v_lo
    hi.value = v_hi

    const span = max - min
    const lpct = span > 0 ? ((v_lo - min) / span) * 100 : 0
    const rpct = span > 0 ? ((max - v_hi) / span) * 100 : 0
    if (this.hasFillTarget) {
      this.fillTarget.style.left  = `${lpct}%`
      this.fillTarget.style.right = `${rpct}%`
    }

    this.toggleName(lo, v_lo > min)
    this.toggleName(hi, v_hi < max)

    if (this.hasDisplayTarget) {
      this.displayTarget.textContent = this.label(v_lo, v_hi, min, max)
    }
  }

  toggleName(input, active) {
    const param = input.dataset.dualRangeNameParam
    if (!param) return
    input.name = active ? param : ""
  }

  label(lo, hi, min, max) {
    const loActive = lo > min
    const hiActive = hi < max
    if (!loActive && !hiActive) return "Any"
    if (loActive && !hiActive)  return `≥ ${this.format(lo)}`
    if (!loActive && hiActive)  return `≤ ${this.format(hi)}`
    return `${this.format(lo)} – ${this.format(hi)}`
  }

  format(v) {
    switch (this.formatValue) {
      case "money": return "$" + v.toLocaleString()
      case "hours": return v + "h"
      default:      return v.toLocaleString()
    }
  }
}
