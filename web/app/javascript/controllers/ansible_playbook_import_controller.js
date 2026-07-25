import { Controller } from "@hotwired/stimulus"
import { apiFetch } from "lib/api_fetch"
import { fileValidationErrors } from "lib/ansible_authoring"
import { AnsiblePlaybookBatchImporter } from "lib/ansible_playbook_batch_importer"

export default class extends Controller {
  static values = {
    indexUrl: String,
    validateUrl: String,
    maxFiles: Number,
    maxFileBytes: Number,
    maxBatchBytes: Number,
  }

  static targets = [
    "fileInput", "dropOverlay", "dialog", "rows", "summary", "close",
    "conflictPanel", "conflictFile", "conflictName",
  ]

  connect() {
    this.dragDepth = 0
    this.active = false
    this.rowViews = new Map()
    this.pendingConflict = null
  }

  disconnect() {
    this.hideDropOverlay()
    if (this.pendingConflict) this.pendingConflict("skip_all")
    this.pendingConflict = null
  }

  filesSelected(event) {
    const files = Array.from(event.target.files || [])
    event.target.value = ""
    this.start(files)
  }

  dragEnter(event) {
    if (!this.isFileDrag(event)) return
    event.preventDefault()
    this.dragDepth += 1
    this.dropOverlayTarget.classList.remove("hidden")
  }

  dragOver(event) {
    if (!this.isFileDrag(event)) return
    event.preventDefault()
    if (event.dataTransfer) event.dataTransfer.dropEffect = "copy"
  }

  dragLeave() {
    if (this.dragDepth === 0) return
    this.dragDepth = Math.max(0, this.dragDepth - 1)
    if (this.dragDepth === 0) this.hideDropOverlay()
  }

  drop(event) {
    if (!this.isFileDrag(event)) return
    event.preventDefault()
    const files = Array.from(event.dataTransfer?.files || [])
    this.dragEnd()
    this.start(files)
  }

  dragEnd() {
    this.dragDepth = 0
    this.hideDropOverlay()
  }

  hideDropOverlay() {
    if (this.hasDropOverlayTarget) this.dropOverlayTarget.classList.add("hidden")
  }

  isFileDrag(event) {
    return Array.from(event.dataTransfer?.types || []).includes("Files")
  }

  async start(files) {
    if (this.active || files.length === 0) return
    this.active = true
    this.rowViews.clear()
    this.rowsTarget.replaceChildren()
    this.summaryTarget.textContent = "Preparing import…"
    this.closeTarget.disabled = true
    this.conflictPanelTarget.classList.add("hidden")
    this.dialogTarget.showModal()

    const listing = await apiFetch(this.indexUrlValue)
    const known = listing.ok && listing.data ? listing.data.playbooks || [] : []
    const importer = new AnsiblePlaybookBatchImporter({
      validateFile: (file) => fileValidationErrors(file, this.maxFileBytesValue),
      validateYaml: async (yaml) => {
        const response = await apiFetch(this.validateUrlValue, {
          method: "POST",
          body: { yaml_content: yaml },
        })
        if (!response.ok || !response.data) throw new Error("validation request failed")
        return response.data
      },
      findByName: async (name) => known.find((item) => item.name.toLocaleLowerCase() === name.toLocaleLowerCase()) || null,
      createPlaybook: async (attributes) => {
        const response = await apiFetch(this.indexUrlValue, { method: "POST", body: attributes })
        if (!response.ok || !response.data) throw new Error("create failed")
        known.push(response.data)
        return response.data
      },
      updatePlaybook: async (existing, attributes) => {
        const response = await apiFetch(`${this.indexUrlValue}/${existing.id}`, { method: "PATCH", body: attributes })
        if (!response.ok || !response.data) throw new Error("update failed")
        const index = known.findIndex((item) => item.id === existing.id)
        if (index >= 0) known.splice(index, 1, response.data)
        return response.data
      },
      resolveConflict: (conflict) => this.resolveConflict(conflict),
      limits: {
        maxFiles: this.maxFilesValue,
        maxFileBytes: this.maxFileBytesValue,
        maxBatchBytes: this.maxBatchBytesValue,
      },
    })

    const result = await importer.run(files, (record) => this.renderProgress(record))
    this.summaryTarget.textContent = ["imported", "updated", "skipped", "failed"]
      .map((state) => `${result.summary[state]} ${state}`)
      .join(" · ")
    this.active = false
    this.closeTarget.disabled = false
    this.conflictPanelTarget.classList.add("hidden")
    this.application.getControllerForElementAndIdentifier(this.element, "ansible-authoring")?.refresh()
    this.closeTarget.focus()
  }

  renderProgress(record) {
    let view = this.rowViews.get(record.index)
    if (!view) {
      const row = document.createElement("div")
      row.className = "grid grid-cols-[minmax(0,1fr)_auto] gap-3 rounded-md border border-zinc-200 px-3 py-2 text-sm dark:border-zinc-800"
      const fileName = document.createElement("span")
      fileName.className = "truncate font-medium"
      fileName.textContent = record.fileName
      const status = document.createElement("span")
      status.className = "text-xs font-medium text-zinc-500"
      const errors = document.createElement("p")
      errors.className = "col-span-2 text-xs text-rose-700 dark:text-rose-300"
      row.append(fileName, status, errors)
      this.rowsTarget.appendChild(row)
      view = { status, errors }
      this.rowViews.set(record.index, view)
    }
    view.status.textContent = record.state
    view.errors.textContent = record.errors.join(" ")
  }

  resolveConflict(conflict) {
    this.conflictFileTarget.textContent = conflict.fileName
    this.conflictNameTarget.textContent = conflict.name
    this.conflictPanelTarget.classList.remove("hidden")
    const first = this.conflictPanelTarget.querySelector("button[data-decision]")
    first?.focus()
    return new Promise((resolve) => { this.pendingConflict = resolve })
  }

  chooseConflict(event) {
    if (!this.pendingConflict) return
    const resolve = this.pendingConflict
    this.pendingConflict = null
    this.conflictPanelTarget.classList.add("hidden")
    resolve(event.currentTarget.dataset.decision)
  }

  trapConflictFocus(event) {
    if (event.key !== "Tab" || this.conflictPanelTarget.classList.contains("hidden")) return
    const controls = Array.from(this.conflictPanelTarget.querySelectorAll("button:not([disabled])"))
    if (controls.length === 0) return
    const first = controls[0]
    const last = controls[controls.length - 1]
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault()
      last.focus()
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault()
      first.focus()
    }
  }

  preventClose(event) {
    if (this.active) event.preventDefault()
  }

  close() {
    if (!this.active) this.dialogTarget.close()
  }
}
