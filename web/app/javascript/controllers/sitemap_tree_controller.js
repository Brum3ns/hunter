// web/app/javascript/controllers/sitemap_tree_controller.js
import { Controller } from "@hotwired/stimulus"

// Owns all sitemap-tree interactivity: expand/collapse folders, lazy-load an
// origin's tree Turbo Frame on first expand, and (Task 4) load endpoint detail.
export default class extends Controller {
  activate(event) {
    const row = event.currentTarget
    const li = row.closest("[data-node]")
    const children = li.querySelector(":scope > [data-children]")

    if (children) {
      const open = children.hidden
      children.hidden = !open
      const chevron = row.querySelector("[data-chevron]")
      if (chevron) chevron.classList.toggle("rotate-90", open)

      // Lazy-load an origin's tree frame the first time it opens.
      const frame = children.querySelector(":scope > turbo-frame[data-src]")
      if (open && frame && !frame.getAttribute("src")) {
        frame.setAttribute("src", frame.getAttribute("data-src"))
      }
    }
  }
}
