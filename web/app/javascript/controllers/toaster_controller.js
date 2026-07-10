import { Controller } from "@hotwired/stimulus"

// Renders transient toast notifications. Mounted once in the layout; any code
// can raise one with: window.dispatchEvent(new CustomEvent("toast", { detail: { message } })).
export default class extends Controller {
  connect() {
    this.onToast = this.show.bind(this)
    window.addEventListener("toast", this.onToast)
  }

  disconnect() {
    window.removeEventListener("toast", this.onToast)
  }

  show(event) {
    const message = (event.detail && event.detail.message) || "Done"

    const toast = document.createElement("div")
    toast.setAttribute("role", "status")
    toast.className =
      "pointer-events-auto translate-y-2 rounded-lg bg-zinc-900 px-3.5 py-2 text-sm font-medium text-white opacity-0 shadow-lg ring-1 ring-black/5 transition-all duration-200 ease-out dark:bg-white dark:text-zinc-900"
    toast.textContent = message
    this.element.appendChild(toast)

    requestAnimationFrame(() => {
      toast.classList.remove("translate-y-2", "opacity-0")
    })

    setTimeout(() => {
      toast.classList.add("opacity-0", "translate-y-2")
      toast.addEventListener("transitionend", () => toast.remove(), { once: true })
    }, 2000)
  }
}
