import { Controller } from "@hotwired/stimulus"

// Owns the asset table's column layout: visibility, order, and width. State is
// a single source of truth ({ order, hidden, widths }) persisted to
// localStorage and applied by rewriting each row's CSS grid template plus the
// `order`/`display` of every cell. Column metadata (default width/visibility)
// is read from the server-rendered header cells.
const STORAGE_KEY = "targets.columns"

export default class extends Controller {
  static targets = ["header", "body", "head", "row"]

  connect() {
    this.defaults = {}
    this.order = []
    this.headTargets.forEach((el) => {
      const col = el.dataset.col
      this.order.push(col)
      this.defaults[col] = {
        width: parseInt(el.dataset.width, 10) || 140,
        visible: el.dataset.default === "true"
      }
    })
    this.hidden = new Set(
      Object.keys(this.defaults).filter((c) => !this.defaults[c].visible)
    )
    this.widths = {}
    Object.keys(this.defaults).forEach((c) => (this.widths[c] = this.defaults[c].width))

    this.load()
    this.bindDragAndDrop()
    this.apply()

    // Rows appended later (infinite scroll) must inherit the current layout;
    // re-apply whenever the body's children change.
    if (this.hasBodyTarget) {
      this.rowObserver = new MutationObserver(() => this.apply())
      this.rowObserver.observe(this.bodyTarget, { childList: true })
    }
  }

  disconnect() {
    if (this.rowObserver) this.rowObserver.disconnect()
  }

  // --- persistence -------------------------------------------------------
  load() {
    try {
      const saved = JSON.parse(localStorage.getItem(STORAGE_KEY))
      if (!saved) return
      if (Array.isArray(saved.order)) {
        const known = new Set(this.order)
        const merged = saved.order.filter((c) => known.has(c))
        this.order.forEach((c) => { if (!merged.includes(c)) merged.push(c) })
        this.order = merged
      }
      if (Array.isArray(saved.hidden)) this.hidden = new Set(saved.hidden)
      if (saved.widths) Object.assign(this.widths, saved.widths)
    } catch (_e) { /* corrupt state — fall back to defaults */ }
  }

  save() {
    localStorage.setItem(STORAGE_KEY, JSON.stringify({
      order: this.order,
      hidden: [...this.hidden],
      widths: this.widths
    }))
  }

  // --- apply -------------------------------------------------------------
  apply() {
    const visible = this.order.filter((c) => !this.hidden.has(c))
    // Fixed px tracks, except the last visible column which flexes to absorb
    // slack so the table fills wide screens; a min-width equal to the fixed sum
    // makes the shared scroll container scroll when columns exceed the width.
    const total = visible.reduce((sum, c) => sum + this.widths[c], 0)
    const template = visible
      .map((c, i) =>
        i === visible.length - 1 ? `minmax(${this.widths[c]}px, 1fr)` : `${this.widths[c]}px`
      )
      .join(" ")

    ;[this.headerTarget, ...this.rowTargets].forEach((rowEl) => {
      rowEl.style.gridTemplateColumns = template
      rowEl.style.minWidth = `${total}px`
      rowEl.querySelectorAll("[data-col]").forEach((cell) => {
        const col = cell.dataset.col
        if (this.hidden.has(col)) {
          cell.style.display = "none"
        } else {
          cell.style.display = ""
          cell.style.order = String(visible.indexOf(col))
        }
      })
    })
  }

  // --- visibility --------------------------------------------------------
  toggle(event) {
    const col = event.target.dataset.col
    if (event.target.checked) this.hidden.delete(col)
    else this.hidden.add(col)
    this.save()
    this.apply()
  }

  // --- reorder (drag headers) -------------------------------------------
  bindDragAndDrop() {
    this.headTargets.forEach((head) => {
      head.addEventListener("dragstart", (e) => {
        this.dragCol = head.dataset.col
        e.dataTransfer.effectAllowed = "move"
      })
      head.addEventListener("dragover", (e) => e.preventDefault())
      head.addEventListener("drop", (e) => {
        e.preventDefault()
        this.moveColumn(this.dragCol, head.dataset.col)
      })
    })
  }

  moveColumn(from, to) {
    if (!from || from === to) return
    const next = this.order.filter((c) => c !== from)
    next.splice(next.indexOf(to), 0, from)
    this.order = next
    this.save()
    this.apply()
  }

  // --- resize (drag the header edge handle) ------------------------------
  startResize(event) {
    event.preventDefault()
    const col = event.target.dataset.col
    const startX = event.clientX
    const startWidth = this.widths[col]

    const onMove = (e) => {
      this.widths[col] = Math.max(60, startWidth + (e.clientX - startX))
      this.apply()
    }
    const onUp = () => {
      document.removeEventListener("mousemove", onMove)
      document.removeEventListener("mouseup", onUp)
      this.save()
    }
    document.addEventListener("mousemove", onMove)
    document.addEventListener("mouseup", onUp)
  }
}
