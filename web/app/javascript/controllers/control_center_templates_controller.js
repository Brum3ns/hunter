import { Controller } from "@hotwired/stimulus"
import { apiFetch } from "lib/api_fetch"
import {
  EditorView, EditorState, basicSetup, yaml, oneDark,
  keymap, indentWithTab, placeholder, Compartment,
} from "codemirror"

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
  ]

  connect() {
    this.editingId = null
    this.sendTemplate = null
    this.mode = "structured"
    this.lastEdited = "structured"
    this._syncing = false
    this._mountEditor()
    this.refresh()
  }

  disconnect() {
    clearTimeout(this._valTimer)
    clearTimeout(this._yamlTimer)
    clearTimeout(this._flashTimer)
    this._themeObserver?.disconnect()
    this.editorView?.destroy()
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
            if (u.docChanged && !this._syncing) { this.lastEdited = "yaml"; this.validateYaml() }
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
    this._setTarget(null)
    this.errorsTarget.classList.add("hidden")
    this.editorTarget.classList.remove("hidden")
    this.sendDialogTarget.classList.add("hidden")
    this.validate()
    this._setYamlValue("")
    this.lastEdited = "structured"
    this.applyStoredMode()
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
    this._setTarget(t.target)
    this.editorTarget.classList.remove("hidden")
    this.sendDialogTarget.classList.add("hidden")
    this.validate()
    this._setYamlValue(t.yaml || "")
    this.lastEdited = "structured"
    this.applyStoredMode()
  }

  closeEditor() { this.editorTarget.classList.add("hidden") }

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

  addCommand(command = null) {
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
    const url = this.editingId ? `${this.indexUrlValue}/${this.editingId}` : this.indexUrlValue
    const method = this.editingId ? "PATCH" : "POST"
    const { ok, data } = await apiFetch(url, { method, body })
    if (ok) {
      if (data && data.id) this.editingId = data.id
      this.refresh()
      if (close) this.closeEditor()
      else this._flashSaved()
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
