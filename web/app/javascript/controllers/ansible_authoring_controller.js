import { Controller } from "@hotwired/stimulus"
import { apiFetch } from "lib/api_fetch"
import {
  downloadFilename,
  fileValidationErrors,
  nextDirtyState,
  normalizeApiErrors,
} from "lib/ansible_authoring"

export default class extends Controller {
  static values = {
    indexUrl: String,
    validateUrl: String,
    resourceType: String,
    maxBytes: Number,
  }

  static targets = [
    "list", "empty", "form", "name", "description", "yaml",
    "validation", "dirty", "uploadInput",
  ]

  connect() {
    this.resources = []
    this.editingId = null
    this.dirty = false
    this.query = ""
    this._beforeUnload = (event) => {
      if (!this.dirty) return
      event.preventDefault()
      event.returnValue = ""
    }
    window.addEventListener("beforeunload", this._beforeUnload)
    this.refresh()
  }

  disconnect() {
    window.removeEventListener("beforeunload", this._beforeUnload)
  }

  async refresh() {
    const { ok, data } = await apiFetch(this.indexUrlValue)
    if (!ok || !data) {
      this.renderValidation(normalizeApiErrors(data), false)
      return
    }
    this.resources = data[this.collectionKey()] || []
    this.renderList()
  }

  collectionKey() {
    return this.resourceTypeValue === "inventory" ? "inventories" : "playbooks"
  }

  renderList() {
    const query = this.query.toLocaleLowerCase()
    const visible = this.resources.filter((resource) =>
      !query || resource.name.toLocaleLowerCase().includes(query),
    )
    this.listTarget.replaceChildren(...visible.map((resource) => this.listItem(resource)))
    this.emptyTarget.classList.toggle("hidden", visible.length > 0)
  }

  listItem(resource) {
    const button = document.createElement("button")
    button.type = "button"
    button.className = "block w-full px-4 py-3 text-left hover:bg-zinc-50 dark:hover:bg-zinc-800/50"
    button.dataset.resourceId = resource.id
    button.addEventListener("click", () => this.openResource(resource))

    const name = document.createElement("span")
    name.className = "block text-sm font-medium text-zinc-900 dark:text-zinc-100"
    name.textContent = resource.name
    const description = document.createElement("span")
    description.className = "mt-0.5 block truncate text-xs text-zinc-500 dark:text-zinc-400"
    description.textContent = resource.description || "No description"
    button.append(name, description)
    if (this.resourceTypeValue !== "playbook") return button

    const row = document.createElement("div")
    row.className = "flex items-center"
    const checkbox = document.createElement("input")
    checkbox.type = "checkbox"
    checkbox.dataset.playbookId = resource.id
    checkbox.setAttribute("data-ansible-playbook-selection-target", "checkbox")
    checkbox.setAttribute("data-action", "ansible-playbook-selection#checkboxChanged")
    checkbox.className = "ml-4 rounded border-zinc-300 dark:border-zinc-700"
    checkbox.setAttribute("aria-label", `Select ${resource.name}`)
    row.append(checkbox, button)
    return row
  }

  search(event) {
    this.query = event.target.value || ""
    this.renderList()
  }

  newResource() {
    if (!this.confirmDiscard()) return
    this.editingId = null
    this.nameTarget.value = ""
    this.descriptionTarget.value = ""
    this.yamlTarget.value = ""
    this.renderValidation([], null)
    this.setDirty(false, "loaded")
    this.dispatch("resource-cleared")
    this.nameTarget.focus()
  }

  openResource(resource) {
    if (!this.confirmDiscard()) return
    this.editingId = resource.id
    this.nameTarget.value = resource.name || ""
    this.descriptionTarget.value = resource.description || ""
    this.yamlTarget.value = resource.yaml_content || ""
    this.renderValidation([], null)
    this.setDirty(false, "loaded")
    this.dispatch("resource-opened", { detail: { resource } })
  }

  confirmDiscard() {
    return !this.dirty || window.confirm("Discard unsaved changes?")
  }

  markDirty() {
    this.setDirty(true, "edit")
  }

  setDirty(value, event) {
    this.dirty = nextDirtyState(value, event)
    this.dirtyTarget.classList.toggle("hidden", !this.dirty)
  }

  async save(event) {
    event.preventDefault()
    const body = {
      name: this.nameTarget.value,
      description: this.descriptionTarget.value,
      yaml_content: this.yamlTarget.value,
    }
    const url = this.editingId ? `${this.indexUrlValue}/${this.editingId}` : this.indexUrlValue
    const method = this.editingId ? "PATCH" : "POST"
    const { ok, data } = await apiFetch(url, { method, body })
    if (!ok || !data) {
      this.renderValidation(normalizeApiErrors(data), false)
      return
    }

    const index = this.resources.findIndex((resource) => resource.id === data.id)
    if (index >= 0) this.resources.splice(index, 1, data)
    else this.resources.push(data)
    this.resources.sort((left, right) => left.name.localeCompare(right.name))
    this.renderList()
    this.setDirty(false, "saved")
    this.openResource(data)
    this.renderValidation(["Saved."], true)
  }

  async validate() {
    const { ok, data } = await apiFetch(this.validateUrlValue, {
      method: "POST",
      body: { yaml_content: this.yamlTarget.value },
    })
    if (!ok || !data) {
      this.renderValidation(normalizeApiErrors(data), false)
      return
    }
    this.renderValidation(data.valid ? ["YAML is valid."] : data.errors, data.valid)
  }

  async delete() {
    if (!this.editingId) {
      this.newResource()
      return
    }
    if (!window.confirm(`Delete ${this.nameTarget.value || this.resourceTypeValue}?`)) return

    const id = this.editingId
    const { ok, data } = await apiFetch(`${this.indexUrlValue}/${id}`, { method: "DELETE" })
    if (!ok) {
      this.renderValidation(normalizeApiErrors(data), false)
      return
    }
    this.resources = this.resources.filter((resource) => resource.id !== id)
    this.dispatch("resource-deleted", { detail: { id } })
    this.renderList()
    this.editingId = null
    this.nameTarget.value = ""
    this.descriptionTarget.value = ""
    this.yamlTarget.value = ""
    this.setDirty(false, "discarded")
    this.dispatch("resource-cleared")
    this.renderValidation(["Deleted."], true)
  }

  async upload(event) {
    const files = Array.from(event.target.files || [])
    event.target.value = ""
    if (files.length !== 1) {
      this.renderValidation(["Choose exactly one YAML file."], false)
      return
    }

    const file = files[0]
    const errors = fileValidationErrors(file, this.maxBytesValue)
    if (errors.length) {
      this.renderValidation(errors, false)
      return
    }

    try {
      this.yamlTarget.value = await file.text()
      this.markDirty()
      this.renderValidation(["YAML loaded as an unsaved draft."], true)
    } catch {
      this.renderValidation(["Could not read the selected file."], false)
    }
  }

  download() {
    const blob = new Blob([this.yamlTarget.value], { type: "text/yaml;charset=utf-8" })
    const url = URL.createObjectURL(blob)
    const link = document.createElement("a")
    link.href = url
    link.download = downloadFilename(this.nameTarget.value)
    link.hidden = true
    document.body.appendChild(link)
    link.click()
    link.remove()
    URL.revokeObjectURL(url)
  }

  renderValidation(messages, valid) {
    const nodes = (messages || []).map((message) => {
      const line = document.createElement("p")
      line.textContent = message
      return line
    })
    this.validationTarget.replaceChildren(...nodes)
    this.validationTarget.className = `mt-3 min-h-6 text-sm ${
      valid === true ? "text-emerald-700 dark:text-emerald-300" :
        valid === false ? "text-rose-700 dark:text-rose-300" : "text-zinc-500"
    }`
  }
}
