const YAML_EXTENSION = /\.ya?ml$/i

export class TemplateBatchImporter {
  constructor({ validateYaml, createTemplate, updateTemplate, resolveConflict, onStatus, maxBytes = 64000 }) {
    this.validateYaml = validateYaml
    this.createTemplate = createTemplate
    this.updateTemplate = updateTemplate
    this.resolveConflict = resolveConflict
    this.onStatus = onStatus
    this.maxBytes = maxBytes
  }

  async run(files, existingTemplates) {
    this.conflictPolicy = null
    const byName = new Map(existingTemplates.map((template) => [template.name, template]))
    const results = Array.from(files).map((file, index) => ({
      index,
      fileName: file.name,
      templateName: null,
      status: "waiting",
      errors: [],
    }))

    results.forEach((result) => this.emit(result))
    for (const [index, file] of Array.from(files).entries()) {
      await this.processFile(file, results[index], byName)
    }
    return results
  }

  async processFile(file, result, byName) {
    if (!YAML_EXTENSION.test(file.name)) {
      return this.fail(result, "Only .yaml and .yml files can be imported.")
    }
    if (file.size > this.maxBytes) {
      return this.fail(result, "File is too large (max 64 KB).")
    }

    this.emit(result, { status: "validating", errors: [] })
    let yaml
    try {
      yaml = await file.text()
    } catch {
      return this.fail(result, "Could not read file.")
    }

    let validation
    try {
      validation = await this.validateYaml(yaml)
    } catch {
      return this.fail(result, "Validation request failed.")
    }
    if (!validation?.ok) return this.fail(result, this.errors(validation?.errors, "Validation failed."))

    const templateName = validation.template?.name
    if (!templateName) return this.fail(result, "Validated YAML did not include a template name.")
    result.templateName = templateName

    const existing = byName.get(templateName)
    if (existing) return this.handleConflict({ file, yaml, result, existing, byName })

    let created
    try {
      created = await this.createTemplate(yaml)
    } catch {
      return this.fail(result, "Import failed.")
    }
    if (!created?.ok) return this.fail(result, this.errors(created?.errors, "Import failed."))
    if (!created.template?.id) return this.fail(result, "Import response did not include a template ID.")

    byName.set(templateName, created.template)
    this.emit(result, { status: "imported", errors: [] })
  }

  async handleConflict({ file, yaml, result, existing, byName }) {
    let action = this.conflictPolicy
    if (!action) {
      let decision
      try {
        decision = await this.resolveConflict({
          fileName: file.name,
          templateName: result.templateName,
          existing,
        })
      } catch {
        return this.fail(result, "Could not resolve template conflict.")
      }
      if (decision === "update_all") this.conflictPolicy = "update"
      if (decision === "skip_all") this.conflictPolicy = "skip"
      action = decision === "update_all" ? "update" : decision === "skip_all" ? "skip" : decision
    }

    if (action !== "update") {
      this.emit(result, { status: "skipped", errors: [] })
      return
    }

    let updated
    try {
      updated = await this.updateTemplate(existing.id, yaml)
    } catch {
      return this.fail(result, "Update failed.")
    }
    if (!updated?.ok) return this.fail(result, this.errors(updated?.errors, "Update failed."))

    byName.set(result.templateName, updated.template || existing)
    this.emit(result, { status: "updated", errors: [] })
  }

  fail(result, errors) {
    this.emit(result, { status: "failed", errors: this.errors(errors, "Import failed.") })
  }

  errors(value, fallback) {
    if (Array.isArray(value)) {
      const errors = value.map(String).filter(Boolean)
      return errors.length ? errors : [fallback]
    }
    if (value) return [String(value)]
    return [fallback]
  }

  emit(result, changes = {}) {
    Object.assign(result, changes)
    this.onStatus({ ...result, errors: [...result.errors] })
  }
}
