// Pure selection state for the Target and Sitemap list pages. The Stimulus
// controller (targets_selection_controller.js) is a thin DOM wrapper over this.
//
// Three composable kinds of selection feed Control Center:
//   - explicit row ids        (ticked endpoint/asset checkboxes)  -> mode:"ids"
//   - whole origins           (ticked origin checkboxes, sitemap) -> mode:"filter" scoped by origin:
//   - "all matching filter"   (bulk mode with an exclude set)     -> mode:"filter"
// `source` ("targets" | "sitemap") and the current search `query` are supplied
// by the controller from data attributes.

// Inclusive index span between two positions, regardless of click direction.
export function rangeIndices(a, b) {
  const lo = Math.min(a, b)
  const hi = Math.max(a, b)
  const out = []
  for (let i = lo; i <= hi; i++) out.push(i)
  return out
}

// AND a quoted `origin:` term onto the current query so a whole-origin
// selection is resolved server-side by the existing sitemap dork parser.
export function originQuery(query, origin) {
  const term = `origin:"${origin}"`
  const q = String(query || "").trim()
  return q ? `${q} ${term}` : term
}

export class TargetSelection {
  constructor({ source = "", query = "" } = {}) {
    this.source = source
    this.query = query
    this.ids = new Set() // ticked row ids (endpoints or assets)
    this.excluded = new Set() // un-ticked ids while allMatching
    this.origins = new Set() // ticked whole-origin strings (sitemap only)
    this.allMatching = false
    this.anchorIndex = null // last-clicked row index, for shift-range
  }

  // Apply a checkbox toggle for a single row id to the right backing set.
  toggleRow(id, checked) {
    if (this.allMatching) {
      checked ? this.excluded.delete(id) : this.excluded.add(id)
    } else {
      checked ? this.ids.add(id) : this.ids.delete(id)
    }
  }

  toggleOrigin(origin, checked) {
    checked ? this.origins.add(origin) : this.origins.delete(origin)
  }

  // A click on the row at `index` (whose new checked state is `checked`).
  // With shift held and a live anchor, the whole span from the anchor to
  // `index` is forced to `checked`. Returns the affected ids and target state
  // so the controller can sync the DOM checkboxes. Always re-anchors on `index`.
  applyClick(orderedIds, index, checked, shift) {
    const span =
      shift && this.anchorIndex != null && this.anchorIndex < orderedIds.length
        ? rangeIndices(this.anchorIndex, index)
        : [index]
    const changed = []
    for (const i of span) {
      const id = orderedIds[i]
      if (id === undefined) continue
      this.toggleRow(id, checked)
      changed.push(id)
    }
    this.anchorIndex = index
    return { ids: changed, checked }
  }

  selectAllMatching() {
    this.allMatching = true
    this.excluded.clear()
    this.origins.clear()
  }

  clear() {
    this.allMatching = false
    this.ids.clear()
    this.excluded.clear()
    this.origins.clear()
    this.anchorIndex = null
  }

  descriptors() {
    if (this.allMatching) {
      return [{ source: this.source, mode: "filter", q: this.query, exclude_ids: [...this.excluded] }]
    }
    const out = []
    if (this.ids.size) out.push({ source: this.source, mode: "ids", ids: [...this.ids] })
    for (const origin of this.origins) {
      out.push({ source: this.source, mode: "filter", q: originQuery(this.query, origin) })
    }
    // Preserve the legacy empty-selection shape so nothing downstream breaks.
    if (out.length === 0) out.push({ source: this.source, mode: "ids", ids: [] })
    return out
  }

  countLabel() {
    if (this.allMatching) return `all matching − ${this.excluded.size}`
    const parts = []
    if (this.ids.size) parts.push(`${this.ids.size}`)
    if (this.origins.size) parts.push(`${this.origins.size} origin${this.origins.size === 1 ? "" : "s"}`)
    return parts.length ? parts.join(" + ") : "0"
  }
}
