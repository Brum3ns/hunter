import { Controller } from "@hotwired/stimulus"

// Submits the status form the moment the dropdown changes — no submit button.
export default class extends Controller {
  submit() {
    this.element.requestSubmit()
  }
}
