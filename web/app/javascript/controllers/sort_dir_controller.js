import { Controller } from "@hotwired/stimulus"

// Flip the sort direction (asc/desc) hidden input and submit the enclosing form.
// Used by the topbar sort control next to the sort-key dropdown.
export default class extends Controller {
  static targets = ["input"]

  toggle(event) {
    event.preventDefault()
    this.inputTarget.value = this.inputTarget.value === "asc" ? "desc" : "asc"
    this.element.closest("form").requestSubmit()
  }
}
