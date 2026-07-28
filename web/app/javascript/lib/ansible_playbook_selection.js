export class PlaybookSelection {
  constructor(ids = []) {
    this.selected = new Set()
    ids.forEach((id) => this.set(id, true))
  }

  set(id, checked) {
    const normalized = Number(id)
    if (!Number.isInteger(normalized)) return
    if (checked) this.selected.add(normalized)
    else this.selected.delete(normalized)
  }

  setVisible(ids, checked) {
    ids.forEach((id) => this.set(id, checked))
  }

  has(id) {
    return this.selected.has(Number(id))
  }

  ids() {
    return Array.from(this.selected)
  }

  visibleState(ids) {
    const visible = ids.map(Number).filter(Number.isInteger)
    const count = visible.filter((id) => this.selected.has(id)).length
    return {
      checked: visible.length > 0 && count === visible.length,
      indeterminate: count > 0 && count < visible.length,
    }
  }
}

export function filenameFromDisposition(disposition) {
  const source = String(disposition || "")
  const encoded = source.match(/filename\*\s*=\s*UTF-8''([^;]+)/i)?.[1]
  const ordinary = source.match(/filename\s*=\s*"([^"]+)"/i)?.[1] ||
    source.match(/filename\s*=\s*([^;]+)/i)?.[1]
  let filename = encoded || ordinary || "hunter-ansible-playbooks.zip"
  try { filename = decodeURIComponent(filename) } catch { /* retain the literal filename */ }
  filename = filename.trim().split(/[\\/]/).pop().replace(/[^A-Za-z0-9._ -]+/g, "-")
  return filename || "hunter-ansible-playbooks.zip"
}
