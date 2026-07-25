import { Controller } from "@hotwired/stimulus"
import { apiFetch } from "lib/api_fetch"
import { normalizeApiErrors } from "lib/ansible_authoring"
import { variablePayload } from "lib/ansible_variables"

export default class extends Controller {
  static values = { indexUrl: String }
  static targets = ["list", "form", "name", "description", "variables", "variableTemplate", "status"]

  connect() {
    this.variableSets = []
    this.editingId = null
    this.query = ""
    this.refresh()
  }

  async refresh() {
    const { ok, data } = await apiFetch(this.indexUrlValue)
    if (!ok || !data) return this.showStatus(normalizeApiErrors(data), false)
    this.variableSets = data.variable_sets || []
    this.renderList()
  }

  renderList() {
    const query = this.query.toLocaleLowerCase()
    const visible = this.variableSets.filter((item) => !query || item.name.toLocaleLowerCase().includes(query))
    this.listTarget.replaceChildren(...visible.map((item) => {
      const button = document.createElement("button")
      button.type = "button"
      button.className = "block w-full border-b border-zinc-100 px-4 py-3 text-left hover:bg-zinc-50 dark:border-zinc-800 dark:hover:bg-zinc-800/50"
      button.addEventListener("click", () => this.openSet(item))
      const name = document.createElement("span")
      name.className = "block text-sm font-medium"
      name.textContent = item.name
      const count = document.createElement("span")
      count.className = "block text-xs text-zinc-500"
      count.textContent = `${item.variables?.length || 0} variables`
      button.append(name, count)
      return button
    }))
  }

  search(event) {
    this.query = event.target.value || ""
    this.renderList()
  }

  newSet() {
    this.editingId = null
    this.nameTarget.value = ""
    this.descriptionTarget.value = ""
    this.variablesTarget.replaceChildren()
    this.showStatus([], null)
    this.nameTarget.focus()
  }

  openSet(variableSet) {
    this.editingId = variableSet.id
    this.nameTarget.value = variableSet.name || ""
    this.descriptionTarget.value = variableSet.description || ""
    this.variablesTarget.replaceChildren(...(variableSet.variables || []).map((variable) => this.rowFor(variable)))
    this.showStatus([], null)
  }

  addVariable() {
    this.variablesTarget.appendChild(this.rowFor({
      name: "", value_type: "string", secret: false, configured: false, value: "",
    }))
  }

  rowFor(variable) {
    const row = this.variableTemplateTarget.content.firstElementChild.cloneNode(true)
    if (variable.id) row.dataset.variableId = variable.id
    row.dataset.configured = String(Boolean(variable.configured))
    row.querySelector("[data-field='name']").value = variable.name || ""
    row.querySelector("[data-field='value-type']").value = variable.value_type || "string"
    row.querySelector("[data-field='secret']").checked = Boolean(variable.secret)
    const value = row.querySelector("[data-field='value']")
    value.value = variable.secret ? "" : this.editableValue(variable.value)
    value.placeholder = variable.secret && variable.configured ? "Configured — leave blank to retain" : "Value"
    return row
  }

  editableValue(value) {
    if (Array.isArray(value) || (value && typeof value === "object")) return JSON.stringify(value, null, 2)
    return value == null ? "" : String(value)
  }

  moveUp(event) {
    const row = event.target.closest("[data-variable-row]")
    if (row?.previousElementSibling) row.parentNode.insertBefore(row, row.previousElementSibling)
  }

  moveDown(event) {
    const row = event.target.closest("[data-variable-row]")
    if (row?.nextElementSibling) row.parentNode.insertBefore(row.nextElementSibling, row)
  }

  async deleteVariable(event) {
    const row = event.target.closest("[data-variable-row]")
    if (!row) return
    const id = row.dataset.variableId
    if (!id) {
      row.remove()
      return
    }
    if (!window.confirm("Delete this variable?")) return
    const { ok, data } = await apiFetch(`${this.indexUrlValue}/${this.editingId}/variables/${id}`, { method: "DELETE" })
    if (!ok) return this.showStatus(normalizeApiErrors(data), false)
    row.remove()
  }

  async save(event) {
    event.preventDefault()
    const setBody = { name: this.nameTarget.value, description: this.descriptionTarget.value }
    const setUrl = this.editingId ? `${this.indexUrlValue}/${this.editingId}` : this.indexUrlValue
    const { ok, data: variableSet } = await apiFetch(setUrl, {
      method: this.editingId ? "PATCH" : "POST",
      body: setBody,
    })
    if (!ok || !variableSet) return this.showStatus(normalizeApiErrors(variableSet), false)
    this.editingId = variableSet.id

    const rows = Array.from(this.variablesTarget.querySelectorAll("[data-variable-row]"))
    for (const [position, row] of rows.entries()) {
      const attributes = {
        name: row.querySelector("[data-field='name']").value,
        valueType: row.querySelector("[data-field='value-type']").value,
        secret: row.querySelector("[data-field='secret']").checked,
        rawValue: row.querySelector("[data-field='value']").value,
        configured: row.dataset.configured === "true",
      }
      const id = row.dataset.variableId
      const url = id ? `${this.indexUrlValue}/${variableSet.id}/variables/${id}` : `${this.indexUrlValue}/${variableSet.id}/variables`
      const result = await apiFetch(url, {
        method: id ? "PATCH" : "POST",
        body: variablePayload(attributes, position),
      })
      if (!result.ok) return this.showStatus(normalizeApiErrors(result.data), false)
    }

    const detail = await apiFetch(`${this.indexUrlValue}/${variableSet.id}`)
    if (!detail.ok || !detail.data) return this.showStatus(normalizeApiErrors(detail.data), false)
    const index = this.variableSets.findIndex((item) => item.id === detail.data.id)
    if (index >= 0) this.variableSets.splice(index, 1, detail.data)
    else this.variableSets.push(detail.data)
    this.variableSets.sort((left, right) => left.name.localeCompare(right.name))
    this.renderList()
    this.openSet(detail.data)
    this.showStatus(["Saved."], true)
  }

  async deleteSet() {
    if (!this.editingId || !window.confirm(`Delete ${this.nameTarget.value || "this variable set"}?`)) return
    const { ok, data } = await apiFetch(`${this.indexUrlValue}/${this.editingId}`, { method: "DELETE" })
    if (!ok) return this.showStatus(normalizeApiErrors(data), false)
    this.variableSets = this.variableSets.filter((item) => item.id !== this.editingId)
    this.renderList()
    this.newSet()
    this.showStatus(["Deleted."], true)
  }

  showStatus(messages, valid) {
    this.statusTarget.replaceChildren(...(messages || []).map((message) => {
      const line = document.createElement("p")
      line.textContent = message
      return line
    }))
    this.statusTarget.className = `mt-3 min-h-6 text-sm ${
      valid === true ? "text-emerald-700 dark:text-emerald-300" :
        valid === false ? "text-rose-700 dark:text-rose-300" : "text-zinc-500"
    }`
  }
}
