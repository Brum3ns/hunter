import { Controller } from "@hotwired/stimulus"

// Makes a findings-table row open the detail drawer. Loads the row's detail URL
// into the shared "vuln_panel" Turbo Frame. Clicks landing on an interactive
// element (the status select, a link, a button) are ignored so those keep
// working without opening the drawer.
export default class extends Controller {
  static values = { url: String, frame: String }

  open(event) {
    if (event.target.closest("a, button, select, option, input, label, form")) return

    const frame = document.getElementById(this.frameValue)
    if (frame) frame.src = this.urlValue
  }
}
