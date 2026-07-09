import { Controller } from "@hotwired/stimulus"

// Click toggle for marking a program as trashed. Mount on the trash button:
//   data-controller="trash-toggle"
//   data-trash-toggle-sid-value="<%= program.sid %>"
//   data-trash-toggle-trashed-value="<%= program_trashed?(program) %>"
//   data-action="click->trash-toggle#toggle"
//
// Optimistically flips color classes, POSTs/DELETEs the trash endpoint, reverts
// on error. stopPropagation prevents the card/row click from bubbling up to the
// modal opener. Unlike the favorite star, the trash icon is stroke-only — we
// signal "lit" via red color + glow rather than filling the SVG.
export default class extends Controller {
  static values = {
    sid: String,
    trashed: Boolean
  }

  toggle(event) {
    event.preventDefault()
    event.stopPropagation()

    const previous = this.trashedValue
    this.trashedValue = !previous
    this.#render()

    const url = `/programs/${this.sidValue}/trash`
    const method = previous ? "DELETE" : "POST"

    fetch(url, {
      method,
      headers: {
        "X-CSRF-Token": this.#csrfToken,
        "Accept": "application/json",
        "X-Requested-With": "XMLHttpRequest"
      },
      credentials: "same-origin"
    })
      .then(r => {
        if (!r.ok) throw new Error(`HTTP ${r.status}`)
        return r.json()
      })
      .then(data => {
        this.trashedValue = data.trashed === true
        this.#render()
      })
      .catch(err => {
        console.warn("trash toggle failed", err)
        this.trashedValue = previous
        this.#render()
      })
  }

  #render() {
    const trashed = this.trashedValue
    this.element.dataset.trashed = trashed ? "true" : "false"

    this.element.classList.toggle("text-zinc-900", trashed)
    this.element.classList.toggle("dark:text-white", trashed)
    this.element.classList.toggle("text-zinc-400", !trashed)

    const label = trashed ? "Restore from trash" : "Move to trash"
    this.element.setAttribute("title", label)
    this.element.setAttribute("aria-label", label)
  }

  get #csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.getAttribute("content") || ""
  }
}
