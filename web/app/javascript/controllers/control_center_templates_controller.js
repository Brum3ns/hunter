import { Controller } from "@hotwired/stimulus"
import { apiFetch } from "lib/api_fetch"

// Templates tab: list/create/edit/delete templates and dispatch jobs. All rows
// and cells are built with createElement/textContent so template-supplied
// strings can never inject HTML.
export default class extends Controller {
  static values = { indexUrl: String, validateUrl: String, jobsUrl: String }
  static targets = [
    "rows", "empty", "editor", "commands", "commandRow", "errors", "save",
    "fName", "fKind", "fOutput", "fTags", "fDescription",
    "sendDialog", "sendName", "sendTargets", "sendQueue", "sendChunk", "sendDelay", "sendResult",
  ]

  connect() {
    this.editingId = null
    this.sendTemplate = null
    this.refresh()
  }

  // --- list ----------------------------------------------------------------

  async refresh() {
    const { ok, data } = await apiFetch(this.indexUrlValue)
    const templates = ok && data ? data.templates : []
    this.render(templates)
  }

  render(templates) {
    this.rowsTarget.replaceChildren()
    this.emptyTarget.classList.toggle("hidden", templates.length > 0)
    templates.forEach((t) => this.rowsTarget.appendChild(this.rowFor(t)))
  }

  rowFor(t) {
    const tr = document.createElement("tr")
    tr.appendChild(this.cell(t.name, "px-4 py-2 font-medium text-zinc-900 dark:text-zinc-100"))
    tr.appendChild(this.cell(t.kind, "px-4 py-2 text-zinc-500 dark:text-zinc-400"))
    const summary = (t.commands || []).map((c) => c.command).join(" ")
    tr.appendChild(this.cell(summary, "px-4 py-2 font-mono text-xs text-zinc-600 dark:text-zinc-300"))
    tr.appendChild(this.cell((t.tags || []).join(", "), "px-4 py-2 text-zinc-500 dark:text-zinc-400"))

    const actions = document.createElement("td")
    actions.className = "px-4 py-2 text-right whitespace-nowrap"
    actions.appendChild(this.button("Send", () => this.openSend(t)))
    actions.appendChild(this.button("Edit", () => this.openEditor(t)))
    actions.appendChild(this.button("Delete", () => this.destroy(t), "text-rose-600"))
    tr.appendChild(actions)
    return tr
  }

  cell(text, className) {
    const td = document.createElement("td")
    td.className = className
    td.textContent = text || ""
    return td
  }

  button(label, onClick, extra = "") {
    const b = document.createElement("button")
    b.type = "button"
    b.textContent = label
    b.className = `ml-3 text-sm font-medium text-zinc-600 hover:text-zinc-900 dark:text-zinc-300 dark:hover:text-white ${extra}`
    b.addEventListener("click", onClick)
    return b
  }

  // --- editor --------------------------------------------------------------

  newTemplate() {
    this.editingId = null
    this.fNameTarget.value = ""
    this.fKindTarget.value = "cmdscript"
    this.fOutputTarget.value = ""
    this.fTagsTarget.value = ""
    this.fDescriptionTarget.value = ""
    this.commandsTarget.replaceChildren()
    this.addCommand()
    this.errorsTarget.classList.add("hidden")
    this.editorTarget.classList.remove("hidden")
    this.sendDialogTarget.classList.add("hidden")
    this.validate()
  }

  openEditor(t) {
    this.editingId = t.id
    this.fNameTarget.value = t.name || ""
    this.fKindTarget.value = t.kind || "cmdscript"
    this.fOutputTarget.value = t.output || ""
    this.fTagsTarget.value = (t.tags || []).join(", ")
    this.fDescriptionTarget.value = t.description || ""
    this.commandsTarget.replaceChildren()
    ;(t.commands || []).forEach((c) => this.addCommand(c))
    if (!(t.commands || []).length) this.addCommand()
    this.editorTarget.classList.remove("hidden")
    this.sendDialogTarget.classList.add("hidden")
    this.validate()
  }

  closeEditor() { this.editorTarget.classList.add("hidden") }

  addCommand(command = null) {
    const row = this.commandRowTarget.content.firstElementChild.cloneNode(true)
    if (command) {
      row.querySelector('[data-field=command]').value = command.command || ""
      row.querySelector('[data-field=args]').value = (command.args || []).join(" ")
      row.querySelector('[data-field=operator]').value = command.operator || ""
    }
    this.commandsTarget.appendChild(row)
  }

  removeCommand(event) {
    event.target.closest("[data-row]").remove()
    this.validate()
  }

  collectCommands() {
    return Array.from(this.commandsTarget.querySelectorAll("[data-row]")).map((row) => ({
      command: row.querySelector('[data-field=command]').value.trim(),
      args: row.querySelector('[data-field=args]').value.trim().split(/\s+/).filter(Boolean),
      operator: row.querySelector('[data-field=operator]').value,
    }))
  }

  async validate() {
    const { ok, data } = await apiFetch(this.validateUrlValue, {
      method: "POST",
      body: { commands: this.collectCommands() },
    })
    const errors = ok && data ? data.errors : ["validation request failed"]
    const valid = ok && data && data.valid && this.fNameTarget.value.trim().length > 0
    this.showErrors(valid ? [] : errors)
    this.saveTarget.disabled = !valid
  }

  showErrors(errors) {
    this.errorsTarget.replaceChildren()
    this.errorsTarget.classList.toggle("hidden", errors.length === 0)
    errors.forEach((msg) => {
      const li = document.createElement("li")
      li.textContent = msg
      this.errorsTarget.appendChild(li)
    })
  }

  async save() {
    const body = {
      name: this.fNameTarget.value.trim(),
      kind: this.fKindTarget.value,
      output: this.fOutputTarget.value.trim(),
      description: this.fDescriptionTarget.value,
      tags: this.fTagsTarget.value.split(",").map((s) => s.trim()).filter(Boolean),
      commands: this.collectCommands(),
    }
    const url = this.editingId ? `${this.indexUrlValue}/${this.editingId}` : this.indexUrlValue
    const method = this.editingId ? "PATCH" : "POST"
    const { ok, data } = await apiFetch(url, { method, body })
    if (ok) {
      this.closeEditor()
      this.refresh()
    } else {
      this.showErrors((data && data.detail) || ["save failed"])
    }
  }

  async destroy(t) {
    if (!window.confirm(`Delete template "${t.name}"?`)) return
    await apiFetch(`${this.indexUrlValue}/${t.id}`, { method: "DELETE" })
    this.refresh()
  }

  // --- send job ------------------------------------------------------------

  openSend(t) {
    this.sendTemplate = t
    this.sendNameTarget.textContent = t.name
    this.sendTargetsTarget.value = ""
    this.sendQueueTarget.value = "test"
    this.sendChunkTarget.value = "0"
    this.sendDelayTarget.value = "0"
    this.sendResultTarget.classList.add("hidden")
    this.sendResultTarget.textContent = ""
    this.sendDialogTarget.classList.remove("hidden")
    this.editorTarget.classList.add("hidden")
  }

  closeSend() { this.sendDialogTarget.classList.add("hidden") }

  async submitJob() {
    const body = {
      template: this.sendTemplate.name,
      targets: this.sendTargetsTarget.value.split("\n").map((s) => s.trim()).filter(Boolean),
      queue_name: this.sendQueueTarget.value.trim() || "test",
      target_chunk: Number(this.sendChunkTarget.value) || 0,
      delay: Number(this.sendDelayTarget.value) || 0,
    }
    const { ok, data } = await apiFetch(this.jobsUrlValue, { method: "POST", body })
    this.sendResultTarget.classList.remove("hidden")
    if (ok && data) {
      this.sendResultTarget.textContent =
        `status: ${data.status}\nexit: ${data.exit_status}\n\n${data.stdout || ""}${data.stderr || ""}`
    } else {
      this.sendResultTarget.textContent = `error: ${JSON.stringify((data && data.detail) || "submit failed")}`
    }
  }
}
