import { Controller } from "@hotwired/stimulus"
import { apiFetch } from "../lib/api_fetch"
import { PollFailures, terminalRunStatus } from "../lib/ansible_run_polling"

export default class extends Controller {
  static targets = ["status", "childStatus", "count", "events", "error", "retry", "cancel"]
  static values = {
    groupUrl: String,
    runUrl: String,
    eventsUrl: String,
    cancelUrl: String,
    status: String,
    poll: { type: Number, default: 2000 },
  }

  connect() {
    this.failures = new PollFailures(3)
    if (!terminalRunStatus(this.statusValue)) this.schedule()
  }

  disconnect() {
    this.stop()
  }

  schedule() {
    this.stop()
    this.timer = setTimeout(() => this.refresh(), this.pollValue)
  }

  stop() {
    if (this.timer) clearTimeout(this.timer)
    this.timer = null
  }

  async refresh() {
    const [groupResponse, runResponse, eventResponse] = await Promise.all([
      apiFetch(this.groupUrlValue),
      apiFetch(this.runUrlValue),
      apiFetch(this.eventsUrlValue),
    ])
    if (![groupResponse, runResponse, eventResponse].every((response) => response.ok)) {
      this.handleFailure()
      return
    }

    this.failures.recordSuccess()
    this.hideError()
    this.renderGroup(groupResponse.data)
    this.renderRun(runResponse.data)
    this.renderEvents(eventResponse.data.events || [])
    if (!terminalRunStatus(groupResponse.data.status)) this.schedule()
  }

  async cancel() {
    if (this.hasCancelTarget) this.cancelTarget.disabled = true
    const response = await apiFetch(this.cancelUrlValue, { method: "POST", body: {} })
    if (!response.ok) {
      this.showError(response.data?.detail || "Unable to request cancellation.")
      if (this.hasCancelTarget) this.cancelTarget.disabled = false
      return
    }
    this.renderGroup(response.data)
    await this.refresh()
  }

  retry() {
    this.failures.recordSuccess()
    this.hideError()
    this.refresh()
  }

  handleFailure() {
    if (this.failures.recordFailure()) {
      this.stop()
      this.showError("Live updates stopped after repeated network errors.")
      if (this.hasRetryTarget) this.retryTarget.classList.remove("hidden")
    } else {
      this.schedule()
    }
  }

  renderGroup(group) {
    this.statusValue = group.status
    if (this.hasStatusTarget) this.statusTarget.textContent = group.status
    if (terminalRunStatus(group.status) && this.hasCancelTarget) this.cancelTarget.classList.add("hidden")
  }

  renderRun(run) {
    if (this.hasChildStatusTarget) this.childStatusTarget.textContent = run.status
    const counts = {
      ok: run.ok_count,
      changed: run.changed_count,
      failed: run.failed_count,
      unreachable: run.unreachable_count,
    }
    this.countTargets.forEach((target) => {
      target.textContent = String(counts[target.dataset.countName] ?? 0)
    })
  }

  renderEvents(events) {
    if (!this.hasEventsTarget) return
    this.eventsTarget.replaceChildren(...events.map((event) => this.eventElement(event)))
  }

  eventElement(event) {
    const article = document.createElement("article")
    article.dataset.eventCounter = String(event.counter)
    article.className = "grid gap-2 px-5 py-4 text-sm md:grid-cols-[5rem_1fr_1fr]"

    const counter = document.createElement("span")
    counter.className = "font-mono text-xs text-zinc-500"
    counter.textContent = `#${event.counter}`
    const summary = document.createElement("span")
    summary.textContent = [event.task || event.event_type, event.host].filter(Boolean).join(" · ")
    const output = document.createElement("pre")
    output.className = "overflow-x-auto whitespace-pre-wrap font-mono text-xs"
    output.textContent = event.stdout || ""
    article.append(counter, summary, output)
    return article
  }

  showError(message) {
    if (!this.hasErrorTarget) return
    this.errorTarget.textContent = message
    this.errorTarget.classList.remove("hidden")
  }

  hideError() {
    if (this.hasErrorTarget) {
      this.errorTarget.textContent = ""
      this.errorTarget.classList.add("hidden")
    }
    if (this.hasRetryTarget) this.retryTarget.classList.add("hidden")
  }
}
