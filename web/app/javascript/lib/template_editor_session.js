export class TemplateEditorSession {
  constructor() {
    this.editingId = null
    this.dirty = false
  }

  markDirty() { this.dirty = true }

  markClean(editingId = null) {
    this.editingId = editingId ?? null
    this.dirty = false
  }

  isEditing(editingId) {
    return this.editingId !== null && editingId !== null && String(this.editingId) === String(editingId)
  }

  mayReplace(confirmDiscard) {
    return !this.dirty || Boolean(confirmDiscard())
  }
}
