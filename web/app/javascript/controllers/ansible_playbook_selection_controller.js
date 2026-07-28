import { Controller } from "@hotwired/stimulus"
import { apiFetchBlob } from "lib/api_fetch"
import { normalizeApiErrors } from "lib/ansible_authoring"
import { PlaybookSelection, filenameFromDisposition } from "lib/ansible_playbook_selection"

export default class extends Controller {
  static values = { exportUrl: String }
  static targets = ["checkbox", "selectAll", "download", "status"]

  connect() {
    this.selection = new PlaybookSelection()
    this.updateControls()
  }

  checkboxTargetConnected(checkbox) {
    checkbox.checked = this.selection?.has(checkbox.dataset.playbookId) || false
    this.updateControls()
  }

  checkboxTargetDisconnected() {
    this.updateControls()
  }

  checkboxChanged(event) {
    this.selection.set(event.currentTarget.dataset.playbookId, event.currentTarget.checked)
    this.updateControls()
  }

  toggleVisible(event) {
    this.selection.setVisible(this.visibleIds(), event.currentTarget.checked)
    this.checkboxTargets.forEach((checkbox) => {
      checkbox.checked = this.selection.has(checkbox.dataset.playbookId)
    })
    this.updateControls()
  }

  resourceDeleted(event) {
    this.selection.set(event.detail.id, false)
    this.updateControls()
  }

  visibleIds() {
    return this.checkboxTargets.map((checkbox) => Number(checkbox.dataset.playbookId))
  }

  updateControls() {
    if (!this.selection || !this.hasDownloadTarget || !this.hasSelectAllTarget) return
    this.downloadTarget.disabled = this.selection.ids().length === 0
    const state = this.selection.visibleState(this.visibleIds())
    this.selectAllTarget.checked = state.checked
    this.selectAllTarget.indeterminate = state.indeterminate
  }

  async download() {
    const ids = this.selection.ids()
    if (ids.length === 0) return
    this.downloadTarget.disabled = true
    this.statusTarget.textContent = "Preparing ZIP…"
    const result = await apiFetchBlob(this.exportUrlValue, { method: "POST", body: { ids } })
    if (!result.ok || !result.blob) {
      this.statusTarget.textContent = normalizeApiErrors(result.data).join(" ")
      this.updateControls()
      return
    }

    const url = URL.createObjectURL(result.blob)
    const link = document.createElement("a")
    link.href = url
    link.download = filenameFromDisposition(result.headers.get("Content-Disposition"))
    link.hidden = true
    document.body.appendChild(link)
    link.click()
    link.remove()
    URL.revokeObjectURL(url)
    this.statusTarget.textContent = `Downloaded ${ids.length} playbook${ids.length === 1 ? "" : "s"}.`
    this.updateControls()
  }
}
