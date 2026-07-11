import { Controller } from "@hotwired/stimulus"

// Live feed for the Programs → Monitor tab. Polls /api/v1/programs/changes for
// new rows (live tail via since_id), loads older rows on demand (before_id),
// and opens the shared program modal when a row is clicked. Rows are built with
// createElement + textContent so program-supplied strings can never inject HTML.
export default class extends Controller {
  static values = { url: String, modalUrl: String, poll: { type: Number, default: 5000 } }
  static targets = ["platform", "kind", "sid", "live", "liveDot", "rows", "empty", "counter", "loadMore", "modalHost"]

  connect() {
    this.changes = new Map()
    this.refresh().then(() => { if (this.liveTarget.checked) this.startPolling() })
  }

  disconnect() {
    this.stopPolling()
    if (this._debounce) clearTimeout(this._debounce)
  }

  // --- user actions --------------------------------------------------------

  filter() { this.refresh() }

  filterDebounced() {
    if (this._debounce) clearTimeout(this._debounce)
    this._debounce = setTimeout(() => this.refresh(), 250)
  }

  toggleLive() {
    if (this.liveTarget.checked) { this.startPolling() } else { this.stopPolling() }
    this.liveDotTarget.classList.toggle("bg-emerald-500", this.liveTarget.checked)
    this.liveDotTarget.classList.toggle("animate-pulse", this.liveTarget.checked)
    this.liveDotTarget.classList.toggle("bg-zinc-300", !this.liveTarget.checked)
  }

  async refresh() {
    this.changes.clear()
    const rows = await this.fetchChanges(this.filterParams())
    rows.forEach((c) => this.changes.set(c.id, c))
    this.render()
  }

  async loadMore() {
    const params = this.filterParams()
    if (this.oldestId()) params.before_id = this.oldestId()
    const rows = await this.fetchChanges(params)
    rows.forEach((c) => this.changes.set(c.id, c))
    this.render()
  }

  async tick() {
    const params = this.filterParams()
    if (this.newestId()) params.since_id = this.newestId()
    const rows = await this.fetchChanges(params)
    if (rows.length) { rows.forEach((c) => this.changes.set(c.id, c)); this.render() }
  }

  // --- data ----------------------------------------------------------------

  filterParams() {
    const params = {}
    if (this.platformTarget.value) params.platform = this.platformTarget.value
    if (this.kindTarget.value) params.kind = this.kindTarget.value
    if (this.sidTarget.value.trim()) params.sid = this.sidTarget.value.trim()
    return params
  }

  async fetchChanges(params) {
    const url = new URL(this.urlValue, window.location.origin)
    Object.entries(params).forEach(([k, v]) => url.searchParams.set(k, v))
    try {
      const res = await fetch(url, { headers: { Accept: "application/json" }, credentials: "same-origin" })
      if (!res.ok) return []
      return (await res.json()).changes || []
    } catch (_e) {
      return []
    }
  }

  newestId() { return this.sortedIds()[0] }
  oldestId() { const ids = this.sortedIds(); return ids[ids.length - 1] }
  sortedIds() { return [...this.changes.keys()].sort((a, b) => b - a) }

  startPolling() { this.stopPolling(); this.timer = setInterval(() => this.tick(), this.pollValue) }
  stopPolling() { if (this.timer) { clearInterval(this.timer); this.timer = null } }

  // --- rendering -----------------------------------------------------------

  render() {
    const items = [...this.changes.values()].sort((a, b) => b.id - a.id)
    this.rowsTarget.replaceChildren(...items.map((c) => this.buildRow(c)))
    this.emptyTarget.classList.toggle("hidden", items.length > 0)
    this.counterTarget.textContent = items.length ? `${items.length} change${items.length === 1 ? "" : "s"}` : "—"
    this.loadMoreTarget.classList.toggle("hidden", items.length === 0)
  }

  buildRow(change) {
    const li = document.createElement("li")
    li.className = "flex items-center gap-3 px-4 py-2.5 text-sm"

    li.appendChild(this.badge(change.platform || "—", "bg-zinc-100 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300"))

    const name = document.createElement("span")
    name.className = "min-w-0 flex-1 truncate font-medium text-zinc-800 dark:text-zinc-100"
    name.textContent = change.program_name || change.program_sid || "(unknown program)"
    li.appendChild(name)

    const detail = document.createElement("span")
    detail.className = "hidden truncate text-xs text-zinc-500 sm:block sm:flex-1 dark:text-zinc-400"
    detail.textContent = this.renderDetail(change)
    li.appendChild(detail)

    li.appendChild(this.badge(this.kindLabel(change.kind), this.kindTone(change.kind)))

    const time = document.createElement("time")
    time.className = "w-28 shrink-0 text-right text-xs tabular-nums text-zinc-400 dark:text-zinc-500"
    if (change.detected_at) { time.dateTime = change.detected_at; time.textContent = this.formatTime(change.detected_at) }
    li.appendChild(time)

    // Every change except a removal links to the (still-existing) program.
    if (change.kind !== "program_removed" && change.program_sid) {
      li.classList.add("cursor-pointer", "hover:bg-zinc-50", "dark:hover:bg-zinc-800/40")
      li.addEventListener("click", () => this.openProgramModal(change.program_sid))
    }
    return li
  }

  badge(text, tone) {
    const span = document.createElement("span")
    span.className = `shrink-0 rounded px-1.5 py-0.5 text-[11px] font-medium ${tone}`
    span.textContent = text
    return span
  }

  kindLabel(kind) { return (kind || "").replaceAll("_", " ") }

  kindTone(kind) {
    if (kind === "program_added" || kind === "scope_added") return "bg-emerald-100 text-emerald-700 dark:bg-emerald-950 dark:text-emerald-300"
    if (kind === "program_removed" || kind === "scope_removed") return "bg-rose-100 text-rose-700 dark:bg-rose-950 dark:text-rose-300"
    if (kind === "bounty_changed") return "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300"
    if (kind === "status_changed") return "bg-sky-100 text-sky-700 dark:bg-sky-950 dark:text-sky-300"
    return "bg-zinc-100 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300"
  }

  renderDetail(change) {
    const from = change.old_value
    const to = change.new_value
    if (change.kind === "bounty_changed") return `${this.bountyLabel(from)} → ${this.bountyLabel(to)}`
    if (change.kind === "status_changed") return `${this.plain(from)} → ${this.plain(to)}`
    if (change.kind.endsWith("_added")) return this.plain(to)
    if (change.kind.endsWith("_removed")) return this.plain(from)
    return ""
  }

  bountyLabel(v) {
    if (!v) return "—"
    const min = v.bounty_min, max = v.bounty_max, cur = v.currency || ""
    if (min == null && max == null) return v.bounty ? "yes" : "no"
    return `${cur}${min ?? "?"}–${max ?? "?"}`.trim()
  }

  plain(v) {
    if (v == null) return "—"
    if (typeof v === "object") return v.asset || v.name || v.status || JSON.stringify(v)
    return String(v)
  }

  formatTime(iso) {
    const d = new Date(iso)
    return isNaN(d) ? "" : d.toLocaleString()
  }

  async openProgramModal(sid) {
    try {
      const res = await fetch(this.modalUrlValue.replace("SID", encodeURIComponent(sid)), { credentials: "same-origin" })
      if (!res.ok) return
      this.modalHostTarget.innerHTML = await res.text()
      const dialog = this.modalHostTarget.querySelector("dialog")
      if (dialog) dialog.showModal()
    } catch (_e) {
      // Transient error — the program is still listed on the Programs tab.
    }
  }
}
