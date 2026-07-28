import { Controller } from "@hotwired/stimulus"
import { apiFetch } from "../lib/api_fetch"

export default class extends Controller {
  static targets = [
    "scanButton", "connectButton", "syntaxButton", "playbook", "status",
    "storedFingerprints", "candidates", "candidateTemplate", "confirmButton",
  ]
  static values = {
    indexUrl: String,
    playbooksUrl: String,
    poll: { type: Number, default: 2000 },
  }

  connect() {
    this.inventory = null
    this.scanCandidates = []
    this.loadPlaybooks()
  }

  disconnect() {
    if (this.timer) clearTimeout(this.timer)
  }

  async loadPlaybooks() {
    const response = await apiFetch(this.playbooksUrlValue)
    if (!response.ok) return
    for (const playbook of response.data.playbooks || []) {
      const option = document.createElement("option")
      option.value = String(playbook.id)
      option.textContent = playbook.name
      this.playbookTarget.append(option)
    }
  }

  resourceOpened(event) {
    this.inventory = event.detail.resource
    this.scanButtonTarget.disabled = false
    this.syntaxButtonTarget.disabled = !this.playbookTarget.value
    this.connectButtonTarget.disabled = !(
      this.inventory.default_credential_id && this.inventory.known_hosts_configured
    )
    this.renderStoredFingerprints()
    this.setStatus("Inventory utility actions are ready.")
  }

  resourceCleared() {
    this.inventory = null
    this.scanButtonTarget.disabled = true
    this.syntaxButtonTarget.disabled = true
    this.connectButtonTarget.disabled = true
    this.setStatus("Save and select an inventory first.")
  }

  async scan() {
    await this.queue("host_key_scan", {})
  }

  playbookChanged() {
    this.syntaxButtonTarget.disabled = !(this.inventory && this.playbookTarget.value)
  }

  async syntax() {
    if (!this.playbookTarget.value) return this.setStatus("Select a playbook first.", false)
    await this.queue("syntax_check", { playbook_id: Number(this.playbookTarget.value) })
  }

  async connectivity() {
    await this.queue("connectivity_test", {})
  }

  async queue(action, body) {
    if (!this.inventory) return
    this.setStatus("Queueing isolated executor task…")
    const response = await apiFetch(`${this.indexUrlValue}/${this.inventory.id}/${action}`, {
      method: "POST",
      body,
    })
    if (!response.ok) return this.setStatus(this.errorMessage(response.data), false)
    this.pollTask(response.data.id)
  }

  async pollTask(taskId) {
    if (!this.inventory) return
    const url = `${this.indexUrlValue}/${this.inventory.id}/executor_tasks/${taskId}`
    const response = await apiFetch(url)
    if (!response.ok) return this.setStatus(this.errorMessage(response.data), false)
    const task = response.data
    if (["queued", "running"].includes(task.status)) {
      this.setStatus(`${task.kind.replaceAll("_", " ")} is ${task.status}…`)
      this.timer = setTimeout(() => this.pollTask(taskId), this.pollValue)
      return
    }
    this.setStatus(task.status === "succeeded" ? "Executor task completed." : (task.error_detail || "Executor task failed."), task.status === "succeeded")
    if (task.kind === "host_key_scan" && task.status === "succeeded") {
      this.scanCandidates = task.result.candidates || []
      this.renderCandidates()
    }
  }

  renderCandidates() {
    const rows = this.scanCandidates.map((candidate) => {
      const fragment = this.candidateTemplateTarget.content.cloneNode(true)
      const row = fragment.querySelector("[data-candidate-row]")
      row._candidate = candidate
      row.querySelector('[data-field="candidate-label"]').textContent = `${candidate.host}:${candidate.port} — untrusted`
      row.querySelector('[data-field="scanned-fingerprint"]').textContent = candidate.fingerprint
      return fragment
    })
    this.candidatesTarget.replaceChildren(...rows)
    this.confirmButtonTarget.hidden = rows.length === 0
  }

  async confirm() {
    const candidates = Array.from(this.candidatesTarget.querySelectorAll("[data-candidate-row]")).map((row) => ({
      host: row._candidate.host,
      port: row._candidate.port,
      known_hosts_line: row._candidate.known_hosts_line,
      scanned_fingerprint: row._candidate.fingerprint,
      expected_fingerprint: row.querySelector('[data-field="expected-fingerprint"]').value,
    }))
    const response = await apiFetch(`${this.indexUrlValue}/${this.inventory.id}/confirm_host_keys`, {
      method: "POST",
      body: { candidates },
    })
    if (!response.ok) return this.setStatus(this.errorMessage(response.data), false)
    this.inventory = response.data
    this.scanCandidates = []
    this.renderCandidates()
    this.renderStoredFingerprints()
    this.connectButtonTarget.disabled = !this.inventory.default_credential_id
    this.setStatus("Host keys confirmed against expected fingerprints.", true)
  }

  renderStoredFingerprints() {
    const entries = Object.entries(this.inventory?.host_key_fingerprints || {})
    const nodes = entries.map(([host, fingerprint]) => {
      const line = document.createElement("p")
      line.className = "break-all font-mono text-xs"
      line.textContent = `${host} ${fingerprint}`
      return line
    })
    this.storedFingerprintsTarget.replaceChildren(...nodes)
    if (!nodes.length) this.storedFingerprintsTarget.textContent = "No host keys approved."
  }

  setStatus(message, valid = null) {
    this.statusTarget.textContent = message
    this.statusTarget.className = `mt-3 min-h-6 text-sm ${
      valid === true ? "text-emerald-700 dark:text-emerald-300" :
        valid === false ? "text-rose-700 dark:text-rose-300" : "text-zinc-500"
    }`
  }

  errorMessage(data) {
    return data?.details?.task?.join(" ") || data?.detail || data?.error || "Request failed."
  }
}
