import { Controller } from "@hotwired/stimulus"

// Click toggle for marking a program as favorite. Mount on the star button:
//   data-controller="favorite-toggle"
//   data-favorite-toggle-sid-value="<%= program.sid %>"
//   data-favorite-toggle-favorited-value="<%= program_favorited?(program) %>"
//   data-action="click->favorite-toggle#toggle"
//
// Optimistically flips icon fill + color classes, POSTs/DELETEs the favorite
// endpoint, reverts on error. stopPropagation prevents the card/row click from
// bubbling up to the modal opener.
export default class extends Controller {
  static values = {
    sid: String,
    favorited: Boolean
  }

  toggle(event) {
    event.preventDefault()
    event.stopPropagation()

    const previous = this.favoritedValue
    this.favoritedValue = !previous
    this.#render()

    const url = `/programs/${this.sidValue}/favorite`
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
        this.favoritedValue = data.favorited === true
        this.#render()
      })
      .catch(err => {
        console.warn("favorite toggle failed", err)
        this.favoritedValue = previous
        this.#render()
      })
  }

  #render() {
    const fav = this.favoritedValue
    this.element.dataset.favorited = fav ? "true" : "false"

    this.element.classList.toggle("text-gold", fav)
    this.element.classList.toggle("text-zinc-400", !fav)

    const svg = this.element.querySelector("svg")
    if (svg) svg.setAttribute("fill", fav ? "currentColor" : "none")

    const label = fav ? "Remove from favorites" : "Add to favorites"
    this.element.setAttribute("title", label)
    this.element.setAttribute("aria-label", fav ? "Unfavorite" : "Favorite")
  }

  get #csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.getAttribute("content") || ""
  }
}
