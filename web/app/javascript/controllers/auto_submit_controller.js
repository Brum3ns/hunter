import { Controller } from "@hotwired/stimulus"

// Debounced form auto-submit. Attach to <form data-controller="auto-submit">
// and trigger from inputs via data-action="input->auto-submit#submit" or
// "change->auto-submit#submit".
export default class extends Controller {
  static values = { wait: { type: Number, default: 250 } }

  submit() {
    clearTimeout(this.timeout)
    this.timeout = setTimeout(() => this.element.requestSubmit(), this.waitValue)
  }
}
