import { Controller } from "@hotwired/stimulus"

// Toggles between "cards" and "table" representations of the programs list.
// Both representations are rendered into the page; CSS visibility flips via
// data-mode on the controller root. Persists choice in localStorage so the
// view follows the user across reloads.
//
// Targets:
//   - cards: the grid container
//   - table: the table container
//   - cardsBtn / tableBtn: the segmented toggle buttons (visual state)
//   - cols: optional element to hide in table mode (the column-count widget)
export default class extends Controller {
  static targets = ["cards", "table", "cardsBtn", "tableBtn", "cols"]
  static values  = { storageKey: { type: String, default: "scope-ui:view" } }

  connect() {
    const stored = localStorage.getItem(this.storageKeyValue)
    const mode = (stored === "table" || stored === "cards") ? stored : "cards"
    this.apply(mode)
  }

  showCards() { this.apply("cards") }
  showTable() { this.apply("table") }

  apply(mode) {
    const isTable = mode === "table"
    if (this.hasCardsTarget) this.cardsTarget.hidden = isTable
    if (this.hasTableTarget) this.tableTarget.hidden = !isTable
    if (this.hasColsTarget)  this.colsTarget.hidden  = isTable
    if (this.hasCardsBtnTarget) this.cardsBtnTarget.dataset.active = String(!isTable)
    if (this.hasTableBtnTarget) this.tableBtnTarget.dataset.active = String(isTable)
    this.element.dataset.mode = mode
    localStorage.setItem(this.storageKeyValue, mode)
  }
}
