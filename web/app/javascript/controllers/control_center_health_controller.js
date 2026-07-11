import { Controller } from "@hotwired/stimulus"
import { apiFetch } from "lib/api_fetch"

// Polls /api/v1/control_center/health and colors the RabbitMQ + Mongo dots.
// green = ok, rose = down/error; the detail string becomes the dot's tooltip.
export default class extends Controller {
  static values = { url: String, poll: { type: Number, default: 15000 } }
  static targets = ["rabbitmqDot", "mongoDot"]

  connect() {
    this.refresh()
    this.timer = setInterval(() => this.refresh(), this.pollValue)
  }

  disconnect() {
    if (this.timer) clearInterval(this.timer)
  }

  async refresh() {
    const { ok, data } = await apiFetch(this.urlValue)
    if (!ok || !data) {
      this.paint(this.rabbitmqDotTarget, false, "unreachable")
      this.paint(this.mongoDotTarget, false, "unreachable")
      return
    }
    this.paint(this.rabbitmqDotTarget, data.rabbitmq?.ok, data.rabbitmq?.detail)
    this.paint(this.mongoDotTarget, data.mongo?.ok, data.mongo?.detail)
  }

  paint(dot, up, detail) {
    dot.classList.toggle("bg-emerald-500", !!up)
    dot.classList.toggle("bg-rose-500", !up)
    dot.classList.remove("bg-zinc-300", "dark:bg-zinc-600")
    dot.title = detail || (up ? "ok" : "down")
  }
}
