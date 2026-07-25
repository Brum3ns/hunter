import { Controller } from "@hotwired/stimulus"
import { apiFetch } from "lib/api_fetch"
import { TemplateBatchImporter } from "lib/template_batch_importer"
import {
  EditorView, EditorState, basicSetup, yaml, oneDark,
  keymap, indentWithTab, placeholder, Compartment,
} from "codemirror"
import { filterTemplates } from "lib/template_search"
import { TemplateEditorSession } from "lib/template_editor_session"

// Templates tab: list/create/edit/delete templates and dispatch jobs. All rows
// and cells are built with createElement/textContent so template-supplied
// strings can never inject HTML.
export default class extends Controller {
  static values = { indexUrl: String, validateUrl: String, jobsUrl: String, validateYamlUrl: String }
  static targets = [
    "rows", "empty", "editor", "commands", "commandRow", "errors", "save", "saveClose", "savedFlash",
    "fName", "fKind", "fOutput", "fTags", "fDescription",
    "fTargetType", "fTargetSep", "fTargetSepCustom", "fTargetOutput", "targetFields", "targetSepCustomWrap",
    "sendDialog", "sendName", "sendTargets", "sendQueue", "sendChunk", "sendDelay", "sendResult",
    "modeStructured", "modeYaml", "modeSplit", "splitWrap", "structuredPanel", "yamlPanel", "yamlEditor", "yamlErrors", "yamlValid", "fileInput",
    "batchFileInput", "dropOverlay", "importDialog", "importRows", "importSummary", "importClose",
    "conflictPanel", "conflictFile", "conflictName",
    "searchInput", "resultCount", "clearSearch", "listError", "noMatches",
  ]

  connect() {
    this.templates = []
    this.listLoaded = false
    this.editorSession = new TemplateEditorSession()
    this.sendTemplate = null
    this.mode = "structured"
    this.lastEdited = "structured"
    this._syncing = false
    this._mountEditor()
    this._dragDepth = 0
    this._importActive = false
    this._importRowViews = new Map()
    this._pendingConflict = null
    this._resetEditor({ guard: false, focus: false })
    this.refresh()
  }

  disconnect() {
    clearTimeout(this._valTimer)
    clearTimeout(this._yamlTimer)
    clearTimeout(this._flashTimer)
    clearTimeout(this._searchTimer)
    this._themeObserver?.disconnect()
    this.editorView?.destroy()
    this._dragDepth = 0
    this.dropOverlayTarget.classList.add("hidden")
    if (this._pendingConflict) this._pendingConflict("skip_all")
    this._pendingConflict = null
  }

  // --- CodeMirror YAML editor ----------------------------------------------

  _mountEditor() {
    this._themeCompartment = new Compartment()
    this.editorView = new EditorView({
      parent: this.yamlEditorTarget,
      state: EditorState.create({
        doc: "",
        extensions: [
          basicSetup, // includes line numbers, history, bracket matching, default keymaps
          yaml(),
          keymap.of([indentWithTab]),
          placeholder("name: 'nuclei-cve'\ncommands:\n  - command: 'nuclei'\n    args:\n      - ['-tags', 'cve']"),
          this._themeCompartment.of(this._darkMode() ? oneDark : []),
          EditorView.theme({
            "&": { fontSize: "0.8125rem" },
            ".cm-scroller": { fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace", minHeight: "16rem", maxHeight: "26rem", overflow: "auto" },
          }),
          EditorView.updateListener.of((u) => {
            if (u.docChanged && !this._syncing) {
              this.editorSession.markDirty()
              this.lastEdited = "yaml"
              this.validateYaml()
            }
          }),
        ],
      }),
    })
    // Follow the app's light/dark toggle (a `.dark` class on <html>).
    this._themeObserver = new MutationObserver(() => {
      this.editorView.dispatch({ effects: this._themeCompartment.reconfigure(this._darkMode() ? oneDark : []) })
    })
    this._themeObserver.observe(document.documentElement, { attributes: true, attributeFilter: ["class"] })
  }

  _darkMode() { return document.documentElement.classList.contains("dark") }

  _yamlValue() { return this.editorView ? this.editorView.state.doc.toString() : "" }

  // Replace the whole document without the change being treated as a user edit
  // (so structured->YAML sync and programmatic loads don't echo back).
  _setYamlValue(str) {
    if (!this.editorView) return
    const prev = this._syncing
    this._syncing = true
    this.editorView.dispatch({ changes: { from: 0, to: this.editorView.state.doc.length, insert: str || "" } })
    this._syncing = prev
  }

  // --- list ----------------------------------------------------------------

  async refresh() {
    const { ok, data } = await apiFetch(this.indexUrlValue)
    if (!ok || !Array.isArray(data?.templates)) {
      this.listErrorTarget.textContent = this.listLoaded
        ? "Could not refresh templates. Showing the last available list."
        : "Could not load templates."
      this.listErrorTarget.classList.remove("hidden")
      this.render()
      return false
    }

    this.templates = data.templates
    this.listLoaded = true
    this.listErrorTarget.textContent = ""
    this.listErrorTarget.classList.add("hidden")
    this.render()
    return true
  }

  render() {
    const query = this.searchInputTarget.value.trim()
    const filtered = filterTemplates(this.templates, query)
    this.rowsTarget.replaceChildren()
    filtered.forEach((template) => this.rowsTarget.appendChild(this.rowFor(template)))
    this.resultCountTarget.textContent = `${filtered.length} of ${this.templates.length} templates`
    this.clearSearchTarget.classList.toggle("hidden", query.length === 0)
    this.emptyTarget.classList.toggle("hidden", !this.listLoaded || this.templates.length > 0)
    this.noMatchesTarget.classList.toggle("hidden", query.length === 0 || this.templates.length === 0 || filtered.length > 0)
  }

  searchChanged() {
    clearTimeout(this._searchTimer)
    this._searchTimer = setTimeout(() => this.render(), 100)
  }

  clearSearch() {
    clearTimeout(this._searchTimer)
    this.searchInputTarget.value = ""
    this.render()
    this.searchInputTarget.focus()
  }

  rowFor(t) {
    const tr = document.createElement("tr")
    tr.tabIndex = 0
    tr.dataset.templateId = t.id
    tr.setAttribute("aria-selected", String(this.editorSession.isEditing(t.id)))
    tr.className = "cursor-pointer outline-none transition-colors hover:bg-zinc-50 focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-zinc-400 dark:hover:bg-zinc-800/50"
    tr.classList.toggle("bg-zinc-100", this.editorSession.isEditing(t.id))
    tr.classList.toggle("dark:bg-zinc-800", this.editorSession.isEditing(t.id))
    tr.addEventListener("click", () => this.selectTemplate(t))
    tr.addEventListener("keydown", (event) => {
      if (event.target !== tr || !["Enter", " "].includes(event.key)) return
      event.preventDefault()
      this.selectTemplate(t)
    })
    tr.appendChild(this.cell(t.name, "px-4 py-2 font-medium text-zinc-900 dark:text-zinc-100"))
    tr.appendChild(this.cell(t.kind, "px-4 py-2 text-zinc-500 dark:text-zinc-400"))
    const summary = (t.commands || []).map((c) => c.command).join(" ")
    tr.appendChild(this.cell(summary, "px-4 py-2 font-mono text-xs text-zinc-600 dark:text-zinc-300"))
    tr.appendChild(this.cell((t.tags || []).join(", "), "px-4 py-2 text-zinc-500 dark:text-zinc-400"))

    const actions = document.createElement("td")
    actions.className = "px-4 py-2 text-right whitespace-nowrap"
    actions.appendChild(this.button("Send", () => this.openSend(t)))
    actions.appendChild(this.button("Edit", () => this.selectTemplate(t)))
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
    b.addEventListener("click", (event) => {
      event.stopPropagation()
      onClick(event)
    })
    return b
  }

  // --- batch YAML import ---------------------------------------------------

  batchFilesSelected(event) {
    const files = Array.from(event.target.files || [])
    event.target.value = ""
    this.startBatchImport(files)
  }

  dragEnter(event) {
    if (!this._isFileDrag(event)) return
    event.preventDefault()
    this._dragDepth += 1
    this.dropOverlayTarget.classList.remove("hidden")
  }

  dragOver(event) {
    if (!this._isFileDrag(event)) return
    event.preventDefault()
    if (event.dataTransfer) event.dataTransfer.dropEffect = "copy"
  }

  dragLeave(event) {
    if (this._dragDepth === 0) return
    this._dragDepth = Math.max(0, this._dragDepth - 1)
    if (this._dragDepth === 0) this.dropOverlayTarget.classList.add("hidden")
  }

  dropFiles(event) {
    if (!this._isFileDrag(event)) return
    event.preventDefault()
    const files = Array.from(event.dataTransfer?.files || [])
    this.dragEnd()
    this.startBatchImport(files)
  }

  dragEnd() {
    this._dragDepth = 0
    this.dropOverlayTarget.classList.add("hidden")
  }

  _isFileDrag(event) {
    return Array.from(event.dataTransfer?.types || []).includes("Files")
  }

  async startBatchImport(files) {
    if (!files.length || this._importActive) return
    this._importActive = true
    this._openImportDialog(files)

    const indexResponse = await apiFetch(this.indexUrlValue)
    if (!indexResponse.ok || !Array.isArray(indexResponse.data?.templates)) {
      const results = files.map((file, index) => ({
        index,
        fileName: file.name,
        templateName: null,
        status: "failed",
        errors: ["Could not load existing templates."],
      }))
      results.forEach((result) => this._renderImportStatus(result))
      this._finishImport(results)
      return
    }

    const importer = new TemplateBatchImporter({
      maxBytes: 64000,
      validateYaml: (yaml) => this._validateImportYaml(yaml),
      createTemplate: (yaml) => this._createImportedTemplate(yaml),
      updateTemplate: (id, yaml) => this._updateImportedTemplate(id, yaml),
      resolveConflict: (conflict) => this._resolveImportConflict(conflict),
      onStatus: (result) => this._renderImportStatus(result),
    })

    const results = await importer.run(files, indexResponse.data.templates)
    await this.refresh()
    this._finishImport(results)
  }

  _openImportDialog(files) {
    this.importRowsTarget.replaceChildren()
    this.importSummaryTarget.classList.add("hidden")
    this.importSummaryTarget.textContent = ""
    this.importCloseTarget.disabled = true
    this.conflictPanelTarget.classList.add("hidden")
    this._importRowViews = new Map()

    files.forEach((file, index) => {
      const row = document.createElement("li")
      row.className = "rounded-lg border border-zinc-200 px-3 py-2 dark:border-zinc-800"

      const line = document.createElement("div")
      line.className = "flex items-center gap-3"
      const name = document.createElement("span")
      name.className = "min-w-0 flex-1 truncate font-mono text-sm"
      name.textContent = file.name
      const badge = document.createElement("span")
      badge.className = this._importBadgeClasses("waiting")
      badge.textContent = "waiting"
      line.append(name, badge)

      const detail = document.createElement("p")
      detail.className = "mt-1 hidden text-xs text-zinc-500 dark:text-zinc-400"
      row.append(line, detail)
      this.importRowsTarget.appendChild(row)
      this._importRowViews.set(index, { badge, detail })
    })

    if (!this.importDialogTarget.open) this.importDialogTarget.showModal()
  }

  _renderImportStatus(result) {
    const view = this._importRowViews.get(result.index)
    if (!view) return
    view.badge.textContent = result.status
    view.badge.className = this._importBadgeClasses(result.status)
    const details = []
    if (result.templateName) details.push(result.templateName)
    if (result.errors?.length) details.push(result.errors.join("; "))
    view.detail.textContent = details.join(" — ")
    view.detail.classList.toggle("hidden", details.length === 0)
  }

  _importBadgeClasses(status) {
    const base = "shrink-0 rounded px-2 py-0.5 text-xs font-medium"
    const colors = {
      waiting: "bg-zinc-100 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300",
      validating: "bg-sky-100 text-sky-700 dark:bg-sky-950/50 dark:text-sky-300",
      imported: "bg-emerald-100 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-300",
      updated: "bg-emerald-100 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-300",
      skipped: "bg-amber-100 text-amber-800 dark:bg-amber-950/50 dark:text-amber-300",
      failed: "bg-rose-100 text-rose-700 dark:bg-rose-950/50 dark:text-rose-300",
    }
    return `${base} ${colors[status] || colors.waiting}`
  }

  async _validateImportYaml(yaml) {
    const { ok, data } = await apiFetch(this.validateYamlUrlValue, { method: "POST", body: { yaml } })
    const valid = ok && data?.valid
    return {
      ok: valid,
      template: data?.template,
      errors: valid ? [] : this._importApiErrors(data, "Validation failed."),
    }
  }

  async _createImportedTemplate(yaml) {
    const { ok, data } = await apiFetch(this.indexUrlValue, { method: "POST", body: { yaml } })
    return { ok, template: ok ? data : null, errors: ok ? [] : this._importApiErrors(data, "Import failed.") }
  }

  async _updateImportedTemplate(id, yaml) {
    const { ok, data } = await apiFetch(`${this.indexUrlValue}/${id}`, { method: "PATCH", body: { yaml } })
    return { ok, template: ok ? data : null, errors: ok ? [] : this._importApiErrors(data, "Update failed.") }
  }

  _importApiErrors(data, fallback) {
    const errors = data?.errors || data?.detail
    if (Array.isArray(errors)) return errors.map(String)
    return errors ? [String(errors)] : [fallback]
  }

  _resolveImportConflict({ fileName, templateName }) {
    this.conflictFileTarget.textContent = fileName
    this.conflictNameTarget.textContent = templateName
    this.conflictPanelTarget.classList.remove("hidden")
    this.conflictPanelTarget.scrollIntoView({ block: "nearest" })
    this.conflictPanelTarget.querySelector("button")?.focus()
    return new Promise((resolve) => { this._pendingConflict = resolve })
  }

  chooseImportConflict(event) {
    if (!this._pendingConflict) return
    const resolve = this._pendingConflict
    this._pendingConflict = null
    this.conflictPanelTarget.classList.add("hidden")
    resolve(event.currentTarget.dataset.decision)
  }

  _finishImport(results) {
    const counts = { imported: 0, updated: 0, skipped: 0, failed: 0 }
    results.forEach((result) => { if (result.status in counts) counts[result.status] += 1 })
    this.importSummaryTarget.textContent =
      `Imported ${counts.imported} · Updated ${counts.updated} · Skipped ${counts.skipped} · Failed ${counts.failed}`
    this.importSummaryTarget.classList.remove("hidden")
    this.importCloseTarget.disabled = false
    this._importActive = false
    this.importCloseTarget.focus()
  }

  preventImportClose(event) {
    if (this._importActive) event.preventDefault()
  }

  closeImport() {
    if (!this._importActive) this.importDialogTarget.close()
  }

  // --- editor --------------------------------------------------------------

  newTemplate() { this._resetEditor() }

  openEditor(template) { this.selectTemplate(template) }

  selectTemplate(template) {
    if (this.editorSession.isEditing(template.id)) return
    if (!this._confirmEditorReplacement()) return
    this._populateEditor(template)
  }

  _confirmEditorReplacement() {
    return this.editorSession.mayReplace(() => window.confirm("Discard unsaved template changes?"))
  }

  _populateEditor(template) {
    this._syncGuard(() => {
      this.fNameTarget.value = template.name || ""
      this.fKindTarget.value = template.kind || "cmdscript"
      this.fOutputTarget.value = template.output || ""
      this.fTagsTarget.value = (template.tags || []).join(", ")
      this.fDescriptionTarget.value = template.description || ""
      this.commandsTarget.replaceChildren()
      ;(template.commands || []).forEach((command) => this.addCommand(command))
      if (!(template.commands || []).length) this.addCommand()
      this._setTarget(template.target)
      this._setYamlValue(template.yaml || "")
    })
    this.errorsTarget.classList.add("hidden")
    if (this.sendDialogTarget.open) this.sendDialogTarget.close()
    this.lastEdited = "structured"
    this.editorSession.markClean(template.id)
    this.applyStoredMode()
    this.render()
    this.fNameTarget.focus()
  }

  _resetEditor({ guard = true, focus = true } = {}) {
    if (guard && !this._confirmEditorReplacement()) return false
    this._syncGuard(() => {
      this.fNameTarget.value = ""
      this.fKindTarget.value = "cmdscript"
      this.fOutputTarget.value = ""
      this.fTagsTarget.value = ""
      this.fDescriptionTarget.value = ""
      this.commandsTarget.replaceChildren()
      this.addCommand()
      this._setTarget(null)
      this._setYamlValue("")
    })
    this.errorsTarget.classList.add("hidden")
    this.lastEdited = "structured"
    this.editorSession.markClean(null)
    this.applyStoredMode()
    this.render()
    if (focus) this.fNameTarget.focus()
    return true
  }

  closeEditor() { this._resetEditor() }

  markEditorDirty() {
    if (!this._syncing) this.editorSession.markDirty()
  }

  // --- editor mode + yaml ---------------------------------------------------

  showStructured() { this.mode = "structured"; this._applyMode(); this.validate() }
  showYaml() { this.mode = "yaml"; this._applyMode(); this.validateYaml() }
  showSplit() { this.mode = "split"; this._applyMode(); this.validate(); this.validateYaml() }

  applyStoredMode() {
    const stored = localStorage.getItem("hunter.cc.editorMode")
    this.mode = ["structured", "yaml", "split"].includes(stored) ? stored : "structured"
    this._applyMode()
    this.validate()
    if (this.mode !== "structured") this.validateYaml()
  }

  _applyMode() {
    const showStruct = this.mode === "structured" || this.mode === "split"
    const showYaml = this.mode === "yaml" || this.mode === "split"
    this.structuredPanelTarget.classList.toggle("hidden", !showStruct)
    this.yamlPanelTarget.classList.toggle("hidden", !showYaml)
    this.splitWrapTarget.classList.toggle("lg:grid-cols-2", this.mode === "split")
    const btns = { structured: this.modeStructuredTarget, yaml: this.modeYamlTarget, split: this.modeSplitTarget }
    Object.entries(btns).forEach(([m, btn]) => {
      const on = m === this.mode
      btn.classList.toggle("bg-zinc-900", on)
      btn.classList.toggle("text-white", on)
      btn.classList.toggle("dark:bg-white", on)
      btn.classList.toggle("dark:text-zinc-900", on)
    })
    localStorage.setItem("hunter.cc.editorMode", this.mode)
    // CodeMirror mounts in a hidden container; re-measure once its pane is shown.
    if (showYaml && this.editorView) this.editorView.requestMeasure()
  }

  onFile(event) {
    const file = event.target.files && event.target.files[0]
    if (!file) return
    if (file.size > 64000) { window.alert("File is too large (max 64 KB)."); event.target.value = ""; return }
    const reader = new FileReader()
    reader.onload = () => {
      this._setYamlValue(String(reader.result || ""))
      this.lastEdited = "yaml"
      this.editorSession.markDirty()
      this.showYaml()
    }
    reader.readAsText(file)
    event.target.value = ""
  }

  // Download the editor's current YAML as <name>.yaml (client-side, no server).
  downloadYaml() {
    const name = (this.fNameTarget.value.trim() || "template")
      .toLowerCase().replace(/[^a-z0-9._-]+/g, "-").replace(/^-+|-+$/g, "") || "template"
    const blob = new Blob([this._yamlValue()], { type: "text/yaml" })
    const url = URL.createObjectURL(blob)
    const a = document.createElement("a")
    a.href = url
    a.download = `${name}.yaml`
    document.body.appendChild(a)
    a.click()
    a.remove()
    URL.revokeObjectURL(url)
  }

  validateDebounced() { clearTimeout(this._valTimer); this._valTimer = setTimeout(() => this.validate(), 300) }
  validateYaml() { clearTimeout(this._yamlTimer); this._yamlTimer = setTimeout(() => this._doValidateYaml(), 300) }

  async _doValidateYaml() {
    if (!this._syncing) this.lastEdited = "yaml"
    const { ok, data } = await apiFetch(this.validateYamlUrlValue, { method: "POST", body: { yaml: this._yamlValue() } })
    const valid = ok && data && data.valid
    const errors = ok && data ? data.errors : ["validation request failed"]
    this.yamlValidTarget.classList.toggle("hidden", !valid)
    this._renderYamlErrors(valid ? [] : errors)
    this.saveTarget.disabled = !valid
    this.saveCloseTarget.disabled = !valid
    // Mirror YAML -> structured while both panes are visible. Only when the YAML
    // parsed (template present), so an in-progress invalid doc never wipes the form.
    if (this.mode === "split" && ok && data && data.template && !this._syncing) {
      this._populateStructured(data.template)
    }
  }

  // Fill the structured form from parsed YAML attrs (validate_yaml). Wrapped in
  // _syncGuard so the input-driven validate() it triggers does not echo back into
  // the YAML pane the user is typing in.
  _populateStructured(attrs) {
    this._syncGuard(() => {
      this.fNameTarget.value = attrs.name || ""
      this.fKindTarget.value = attrs.kind || "cmdscript"
      this.fOutputTarget.value = attrs.output || ""
      this.fTagsTarget.value = (attrs.tags || []).join(", ")
      this.fDescriptionTarget.value = attrs.description || ""
      this.commandsTarget.replaceChildren()
      ;(attrs.commands || []).forEach((c) => this.addCommand(c))
      if (!(attrs.commands || []).length) this.addCommand()
      this._setTarget(attrs.target)
    })
  }

  _syncGuard(fn) {
    this._syncing = true
    try { fn() } finally { this._syncing = false }
  }

  // --- target block --------------------------------------------------------

  // Named separators <-> their real characters. Custom falls through to the text
  // field so arbitrary separators are still expressible.
  static SEPARATORS = { newline: "\n", comma: ",", space: " ", tab: "\t" }

  // { type, separator, output } for the save/validate payload, or null when the
  // Type select is None (so no target block is sent and the renderer omits it).
  collectTarget() {
    const type = this.fTargetTypeTarget.value
    if (!type) return null
    const sel = this.fTargetSepTarget.value
    const separator = sel === "custom"
      ? this.fTargetSepCustomTarget.value
      : this.constructor.SEPARATORS[sel] ?? "\n"
    return { type, separator, output: this.fTargetOutputTarget.value.trim() }
  }

  // Populate the target controls from a parsed target hash (or clear to None).
  _setTarget(target) {
    const type = (target && target.type) || ""
    this.fTargetTypeTarget.value = ["file", "stdin"].includes(type) ? type : ""
    const sep = target ? String(target.separator ?? "") : "\n"
    const named = Object.keys(this.constructor.SEPARATORS).find((k) => this.constructor.SEPARATORS[k] === sep)
    if (target && !named) {
      this.fTargetSepTarget.value = "custom"
      this.fTargetSepCustomTarget.value = sep
    } else {
      this.fTargetSepTarget.value = named || "newline"
      this.fTargetSepCustomTarget.value = ""
    }
    this.fTargetOutputTarget.value = (target && target.output) || ""
    this._applyTargetVisibility()
  }

  targetChanged() {
    this._applyTargetVisibility()
    this.validateDebounced()
  }

  _applyTargetVisibility() {
    this.targetFieldsTarget.classList.toggle("hidden", !this.fTargetTypeTarget.value)
    this.targetSepCustomWrapTarget.classList.toggle("hidden", this.fTargetSepTarget.value !== "custom")
  }

  _renderYamlErrors(errors) {
    this.yamlErrorsTarget.replaceChildren()
    this.yamlErrorsTarget.classList.toggle("hidden", errors.length === 0)
    errors.forEach((msg) => {
      const li = document.createElement("li")
      li.textContent = msg
      this.yamlErrorsTarget.appendChild(li)
    })
  }

  addCommand(commandOrEvent = null) {
    const fromUser = typeof Event !== "undefined" && commandOrEvent instanceof Event
    const command = fromUser ? null : commandOrEvent
    if (fromUser && !this._syncing) this.editorSession.markDirty()
    const row = this.commandRowTarget.content.firstElementChild.cloneNode(true)
    if (command) {
      row.querySelector('[data-field=command]').value = command.command || ""
      row.querySelector('[data-field=args]').value = this.joinArgs(command.args || [])
      row.querySelector('[data-field=operator]').value = command.operator || ""
    }
    this.commandsTarget.appendChild(row)
  }

  removeCommand(event) {
    event.target.closest("[data-row]").remove()
    this.editorSession.markDirty()
    this.validate()
  }

  collectCommands() {
    return Array.from(this.commandsTarget.querySelectorAll("[data-row]")).map((row) => ({
      command: row.querySelector('[data-field=command]').value.trim(),
      args: this.splitArgs(row.querySelector('[data-field=args]').value),
      operator: row.querySelector('[data-field=operator]').value,
    }))
  }

  // Split the args field into argv tokens, shell-style: whitespace separates,
  // but single quotes, double quotes, and backslash escapes group a run into one
  // token so a value with spaces (e.g. -H 'User-Agent: a b') stays a single arg.
  // Single quotes are literal; double quotes and unquoted text honor \\ escapes.
  // The exact inverse of joinArgs, so args round-trip through the editor.
  splitArgs(input) {
    const s = String(input || "")
    const tokens = []
    let cur = ""
    let started = false
    let i = 0
    while (i < s.length) {
      const ch = s[i]
      if (ch === "'") {
        started = true; i++
        while (i < s.length && s[i] !== "'") { cur += s[i]; i++ }
        i++
      } else if (ch === '"') {
        started = true; i++
        while (i < s.length && s[i] !== '"') {
          if (s[i] === "\\" && (s[i + 1] === '"' || s[i + 1] === "\\")) { cur += s[i + 1]; i += 2 }
          else { cur += s[i]; i++ }
        }
        i++
      } else if (ch === "\\" && i + 1 < s.length) {
        cur += s[i + 1]; i += 2; started = true
      } else if (/\s/.test(ch)) {
        if (started) { tokens.push(cur); cur = ""; started = false }
        i++
      } else {
        cur += ch; started = true; i++
      }
    }
    if (started) tokens.push(cur)
    return tokens
  }

  // Render an args array back into a single field, quoting any token that would
  // otherwise re-split (contains whitespace or a quote) or is empty. Inverse of
  // splitArgs.
  joinArgs(args) {
    return (args || []).map((a) => this.quoteArg(String(a))).join(" ")
  }

  quoteArg(arg) {
    if (arg === "") return "''"
    if (!/[\s'"\\]/.test(arg)) return arg
    if (!arg.includes("'")) return `'${arg}'`
    return `"${arg.replace(/(["\\])/g, "\\$1")}"`
  }

  // The structured form as a create/validate payload. `target` is included only
  // when a Type is chosen, so None-target templates render without the block.
  _structuredBody() {
    const body = {
      name: this.fNameTarget.value.trim(),
      kind: this.fKindTarget.value,
      output: this.fOutputTarget.value.trim(),
      description: this.fDescriptionTarget.value,
      tags: this.fTagsTarget.value.split(",").map((s) => s.trim()).filter(Boolean),
      commands: this.collectCommands(),
    }
    const target = this.collectTarget()
    if (target) body.target = target
    return body
  }

  async validate() {
    if (!this._syncing) this.lastEdited = "structured"
    const { ok, data } = await apiFetch(this.validateUrlValue, { method: "POST", body: this._structuredBody() })
    const errors = ok && data ? data.errors : ["validation request failed"]
    const valid = ok && data && data.valid && this.fNameTarget.value.trim().length > 0
    this.showErrors(valid ? [] : errors)
    this.saveTarget.disabled = !valid
    this.saveCloseTarget.disabled = !valid
    // Mirror structured -> YAML when the YAML pane is visible. _setYamlValue marks
    // the change as programmatic, so the editor's update listener does not echo it.
    if (this.mode !== "structured" && ok && data && typeof data.yaml === "string" && !this._syncing) {
      this._setYamlValue(data.yaml)
    }
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

  save() { this._save({ close: false }) }
  saveAndClose() { this._save({ close: true }) }

  async _save({ close }) {
    let body
    const source = this.lastEdited === "yaml" ? "yaml" : "structured"
    if (source === "yaml") {
      body = { yaml: this._yamlValue() }
    } else {
      body = this._structuredBody()
    }
    const editingId = this.editorSession.editingId
    const url = editingId ? `${this.indexUrlValue}/${editingId}` : this.indexUrlValue
    const method = editingId ? "PATCH" : "POST"
    const { ok, data } = await apiFetch(url, { method, body })
    if (ok) {
      const savedId = data?.id ?? editingId
      this.editorSession.markClean(savedId)
      await this.refresh()
      if (close) this._resetEditor({ guard: false })
      else {
        this.render()
        this._flashSaved()
      }
    } else if (source === "yaml") {
      this._renderYamlErrors((data && data.detail) || ["save failed"])
    } else {
      this.showErrors((data && data.detail) || ["save failed"])
    }
  }

  _flashSaved() {
    this.savedFlashTarget.classList.remove("hidden")
    clearTimeout(this._flashTimer)
    this._flashTimer = setTimeout(() => this.savedFlashTarget.classList.add("hidden"), 1500)
  }

  async destroy(template) {
    if (!window.confirm(`Delete template "${template.name}"?`)) return
    const { ok } = await apiFetch(`${this.indexUrlValue}/${template.id}`, { method: "DELETE" })
    if (!ok) return

    const deletedSelection = this.editorSession.isEditing(template.id)
    await this.refresh()
    if (deletedSelection) this._resetEditor({ guard: false })
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
    if (!this.sendDialogTarget.open) this.sendDialogTarget.showModal()
  }

  closeSend() { this.sendDialogTarget.close() }

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
