import { Controller } from "@hotwired/stimulus"

// Run table for the Programs → Logs tab. Polls /api/v1/programs/runs, keeps
// in-flight rows updating until they finish, and expands a row to show its
// captured stdout/stderr. Rows are built with createElement + textContent so
// captured output can never inject HTML.
export default class extends Controller {
  static values = { url: String, poll: { type: Number, default: 3000 } }
  static targets = ["kind", "platform", "status", "mine", "live", "liveDot", "rows", "empty", "counter", "loadMore"]

  connect() {
    this.runs = new Map()
    this.expanded = new Set()
    this.refresh().then(() => { if (this.liveTarget.checked) this.startPolling() })
  }

  disconnect() { this.stopPolling() }

  // --- user actions --------------------------------------------------------

  filter() { this.refresh() }

  toggleLive() {
    if (this.liveTarget.checked) { this.startPolling() } else { this.stopPolling() }
    this.liveDotTarget.classList.toggle("bg-emerald-500", this.liveTarget.checked)
    this.liveDotTarget.classList.toggle("animate-pulse", this.liveTarget.checked)
    this.liveDotTarget.classList.toggle("bg-zinc-300", !this.liveTarget.checked)
  }

  async refresh() {
    this.runs.clear()
    const rows = await this.fetchRuns(this.filterParams())
    rows.forEach((r) => this.runs.set(r.id, r))
    this.render()
  }

  async loadMore() {
    const params = this.filterParams()
    if (this.oldestId()) params.before_id = this.oldestId()
    const rows = await this.fetchRuns(params)
    rows.forEach((r) => this.runs.set(r.id, r))
    this.render()
  }

  async tick() {
    const params = this.filterParams()
    if (this.newestFinishedId()) params.since_id = this.newestFinishedId()
    const rows = await this.fetchRuns(params)
    if (rows.length) { rows.forEach((r) => this.runs.set(r.id, r)); this.render() }
  }

  // --- data ----------------------------------------------------------------

  filterParams() {
    const params = {}
    if (this.kindTarget.value) params.kind = this.kindTarget.value
    if (this.platformTarget.value) params.platform = this.platformTarget.value
    if (this.statusTarget.value) params.status = this.statusTarget.value
    if (this.mineTarget.checked) params.mine = "1"
    return params
  }

  async fetchRuns(params) {
    const url = new URL(this.urlValue, window.location.origin)
    Object.entries(params).forEach(([k, v]) => url.searchParams.set(k, v))
    try {
      const res = await fetch(url, { headers: { Accept: "application/json" }, credentials: "same-origin" })
      if (!res.ok) return []
      return (await res.json()).runs || []
    } catch (_e) {
      return []
    }
  }

  sortedIds() { return [...this.runs.keys()].sort((a, b) => b - a) }
  oldestId() { const ids = this.sortedIds(); return ids[ids.length - 1] }
  // Watermark for live tail: the newest *finished* row. In-flight rows are left
  // below the watermark so they keep being re-pulled until they complete.
  newestFinishedId() {
    const finished = [...this.runs.values()].filter((r) => !r.in_flight).map((r) => r.id).sort((a, b) => b - a)
    return finished[0]
  }

  startPolling() { this.stopPolling(); this.timer = setInterval(() => this.tick(), this.pollValue) }
  stopPolling() { if (this.timer) { clearInterval(this.timer); this.timer = null } }

  // --- rendering -----------------------------------------------------------

  render() {
    const items = [...this.runs.values()].sort((a, b) => b.id - a.id)
    this.rowsTarget.replaceChildren(...items.map((r) => this.buildRow(r)))
    this.emptyTarget.classList.toggle("hidden", items.length > 0)
    this.counterTarget.textContent = items.length ? `${items.length} run${items.length === 1 ? "" : "s"}` : "—"
    this.loadMoreTarget.classList.toggle("hidden", items.length === 0)
  }

  buildRow(run) {
    const wrap = document.createElement("div")

    const row = document.createElement("button")
    row.type = "button"
    row.className = "grid w-full grid-cols-[150px_90px_110px_1fr_80px_90px] items-center gap-2 px-4 py-2.5 text-left text-sm hover:bg-zinc-50 dark:hover:bg-zinc-800/40"
    row.append(
      this.cell(this.formatTime(run.started_at), "tabular-nums text-zinc-500 dark:text-zinc-400"),
      this.cell(run.kind, "text-zinc-700 dark:text-zinc-200"),
      this.cell(run.platform || "—", "text-zinc-600 dark:text-zinc-300"),
      this.cell(this.detail(run), "truncate text-zinc-500 dark:text-zinc-400"),
      this.cell(run.duration_ms != null ? `${run.duration_ms} ms` : "—", "tabular-nums text-zinc-500 dark:text-zinc-400")
    )
    row.appendChild(this.statusPill(run))
    row.addEventListener("click", () => this.toggle(run.id, wrap))
    wrap.appendChild(row)

    if (this.expanded.has(run.id)) wrap.appendChild(this.detailPanel(run))
    return wrap
  }

  cell(text, cls) {
    const span = document.createElement("span")
    span.className = cls
    span.textContent = text == null ? "" : String(text)
    return span
  }

  detail(run) {
    const bits = []
    if (run.mode) bits.push(run.mode)
    if (run.bug_bounty) bits.push("bb")
    if (run.vdp) bits.push("vdp")
    if (Array.isArray(run.programs) && run.programs.length) bits.push(`${run.programs.length} program(s)`)
    if (run.error_class) bits.push(run.error_class)
    return bits.join(" · ")
  }

  statusPill(run) {
    const span = document.createElement("span")
    let text, tone
    if (run.in_flight) { text = "running"; tone = "bg-sky-100 text-sky-700 animate-pulse dark:bg-sky-950 dark:text-sky-300" }
    else if (run.success) { text = "ok"; tone = "bg-emerald-100 text-emerald-700 dark:bg-emerald-950 dark:text-emerald-300" }
    else { text = run.exit_status != null ? `exit ${run.exit_status}` : "error"; tone = "bg-rose-100 text-rose-700 dark:bg-rose-950 dark:text-rose-300" }
    span.className = `justify-self-start rounded px-1.5 py-0.5 text-[11px] font-medium ${tone}`
    span.textContent = text
    return span
  }

  detailPanel(run) {
    const panel = document.createElement("div")
    panel.className = "border-t border-zinc-100 bg-zinc-50 px-4 py-3 text-xs dark:border-zinc-800 dark:bg-zinc-900/40"

    const meta = document.createElement("div")
    meta.className = "mb-2 flex flex-wrap gap-x-4 gap-y-1 text-zinc-500 dark:text-zinc-400"
    const facts = [
      ["run", run.id], ["trigger", run.trigger], ["finished", this.formatTime(run.finished_at)],
      ["exit", run.exit_status], ["stdout", run.stdout_bytes != null ? `${run.stdout_bytes} B` : null], ["user", run.user]
    ]
    facts.forEach(([k, v]) => { if (v != null && v !== "") meta.appendChild(this.cell(`${k}: ${v}`, "")) })
    panel.appendChild(meta)

    if (run.stdout_excerpt) panel.appendChild(this.pre(run.stdout_excerpt))
    if (run.stderr_excerpt) panel.appendChild(this.pre(run.stderr_excerpt, "text-rose-600 dark:text-rose-400"))
    if (!run.stdout_excerpt && !run.stderr_excerpt) panel.appendChild(this.cell("No output captured.", "text-zinc-400"))
    return panel
  }

  pre(text, cls = "text-zinc-700 dark:text-zinc-300") {
    const pre = document.createElement("pre")
    pre.className = `mt-1 max-h-64 overflow-auto whitespace-pre-wrap rounded bg-white p-2 font-mono text-[11px] ${cls} dark:bg-zinc-950`
    pre.textContent = text
    return pre
  }

  toggle(id, wrap) {
    if (this.expanded.has(id)) { this.expanded.delete(id) } else { this.expanded.add(id) }
    const run = this.runs.get(id)
    const existing = wrap.querySelector(":scope > div")
    if (this.expanded.has(id)) { wrap.appendChild(this.detailPanel(run)) }
    else if (existing) { existing.remove() }
  }

  formatTime(iso) {
    if (!iso) return "—"
    const d = new Date(iso)
    return isNaN(d) ? "—" : d.toLocaleString()
  }
}
