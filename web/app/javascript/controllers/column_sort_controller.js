import { Controller } from "@hotwired/stimulus"

// Makes table-view column headers act as sort triggers. Click a header to
// sort by that column; click the active header again to flip direction.
// Writes into the form's existing sort-key select and dir hidden input so
// server-side handling is identical to the topbar sort control.
//
// Mount on the header row with the currently-active key/dir as values:
//   data-controller="column-sort"
//   data-column-sort-key-value="<%= @sort_key %>"
//   data-column-sort-dir-value="<%= @sort_dir %>"
//
// Per-column button:
//   data-action="click->column-sort#sort"
//   data-sort-key="reports"
//   data-default-dir="desc"
export default class extends Controller {
  static values = { key: String, dir: String }

  sort(event) {
    const btn = event.currentTarget
    const key = btn.dataset.sortKey
    if (!key) return
    const defaultDir = btn.dataset.defaultDir || "desc"
    const dir = (key === this.keyValue)
      ? (this.dirValue === "asc" ? "desc" : "asc")
      : defaultDir

    const form = this.element.closest("form")
    if (!form) return
    const sortField = form.querySelector('[name="sort"]')
    const dirField = form.querySelector('[name="dir"]')
    if (sortField) sortField.value = key
    if (dirField) dirField.value = dir
    form.requestSubmit()
  }
}
