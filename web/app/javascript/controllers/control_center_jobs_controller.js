import { Controller } from "@hotwired/stimulus"
import { apiFetch } from "lib/api_fetch"

// Jobs tab: submission history + a stdout/stderr detail panel. Rows are built
// with createElement/textContent. Submit is synchronous server-side, so a job
// arrives here already succeeded/failed — a manual Refresh is enough.
export default class extends Controller {
  static values = { indexUrl: String }
  static targets = ["rows", "empty", "detail"]

  connect() { this.refresh() }

  async refresh() {
    const { ok, data } = await apiFetch(this.indexUrlValue)
    const jobs = ok && data ? data.jobs : []
    this.rowsTarget.replaceChildren()
    this.emptyTarget.classList.toggle("hidden", jobs.length > 0)
    jobs.forEach((j) => this.rowsTarget.appendChild(this.rowFor(j)))
  }

  rowFor(j) {
    const tr = document.createElement("tr")
    tr.className = "cursor-pointer hover:bg-zinc-50 dark:hover:bg-zinc-800/40"
    tr.addEventListener("click", () => this.showDetail(j.id))
    tr.appendChild(this.cell(j.template_name, "px-4 py-2 font-medium text-zinc-900 dark:text-zinc-100"))
    tr.appendChild(this.cell(j.queue_name, "px-4 py-2 text-zinc-500 dark:text-zinc-400"))
    tr.appendChild(this.cell(String(j.target_count), "px-4 py-2 text-zinc-500 dark:text-zinc-400"))
    tr.appendChild(this.statusCell(j.status))
    tr.appendChild(this.cell(this.time(j.created_at), "px-4 py-2 text-zinc-500 dark:text-zinc-400"))
    return tr
  }

  cell(text, className) {
    const td = document.createElement("td")
    td.className = className
    td.textContent = text || ""
    return td
  }

  statusCell(status) {
    const td = document.createElement("td")
    td.className = "px-4 py-2"
    const badge = document.createElement("span")
    const tone = {
      succeeded: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950/50 dark:text-emerald-300",
      failed: "bg-rose-100 text-rose-800 dark:bg-rose-950/50 dark:text-rose-300",
      pending: "bg-zinc-100 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300",
    }[status] || "bg-zinc-100 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300"
    badge.className = `rounded px-1.5 py-0.5 text-xs font-medium ${tone}`
    badge.textContent = status || "unknown"
    td.appendChild(badge)
    return td
  }

  time(iso) {
    if (!iso) return ""
    const d = new Date(iso)
    return Number.isNaN(d.getTime()) ? iso : d.toLocaleString()
  }

  async showDetail(id) {
    const { ok, data } = await apiFetch(`${this.indexUrlValue}/${id}`)
    if (!ok || !data) return
    this.detailTarget.classList.remove("hidden")
    this.detailTarget.textContent =
      `${data.template_name} — ${data.status} (exit ${data.exit_status ?? "—"})\n\n` +
      `$ stdout\n${data.stdout || ""}\n\n$ stderr\n${data.stderr || ""}`
  }
}
