import { Controller } from "@hotwired/stimulus"

// Persisted, foldable sidebar + mobile drawer + theme toggle.
export default class extends Controller {
  static targets = ["aside", "label", "backdrop"]

  // Desktop: fold/unfold and persist in the sidebar_folded cookie.
  toggle() {
    const folded = this.asideTarget.classList.toggle("md:w-12")
    this.asideTarget.classList.toggle("md:w-44", !folded)
    this.labelTargets.forEach((el) => el.classList.toggle("md:hidden", folded))
    const chevron = this.asideTarget.querySelector("[data-action='sidebar#toggle'] svg")
    if (chevron) chevron.classList.toggle("rotate-180", folded)
    this.#setCookie("sidebar_folded", folded ? "1" : "0")
  }

  // Mobile: slide the drawer in.
  open() {
    this.asideTarget.classList.remove("-translate-x-full")
    if (this.hasBackdropTarget) this.backdropTarget.classList.remove("hidden")
  }

  // Mobile: slide the drawer out.
  close() {
    this.asideTarget.classList.add("-translate-x-full")
    if (this.hasBackdropTarget) this.backdropTarget.classList.add("hidden")
  }

  // Toggle light/dark and persist in the theme cookie.
  toggleTheme() {
    const isDark = document.documentElement.classList.toggle("dark")
    this.#setCookie("theme", isDark ? "dark" : "light")
  }

  #setCookie(name, value) {
    const oneYear = 60 * 60 * 24 * 365
    document.cookie = `${name}=${value}; path=/; max-age=${oneYear}; SameSite=Lax`
  }
}
