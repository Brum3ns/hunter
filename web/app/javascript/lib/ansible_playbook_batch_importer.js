const TERMINAL_STATES = ["imported", "updated", "skipped", "failed"]

export function normalizePlaybookName(filename) {
  const source = String(filename || "")
  if (!/\.ya?ml$/i.test(source)) return null
  const stem = source.replace(/\.ya?ml$/i, "")
  const safe = stem
    .replace(/[^A-Za-z0-9._-]+/g, "-")
    .replace(/^[-_.]+|[-_.]+$/g, "")
  return safe || null
}

export class AnsiblePlaybookBatchImporter {
  constructor({
    validateFile,
    validateYaml,
    findByName,
    createPlaybook,
    updatePlaybook,
    resolveConflict,
    limits,
  }) {
    this.validateFile = validateFile
    this.validateYaml = validateYaml
    this.findByName = findByName
    this.createPlaybook = createPlaybook
    this.updatePlaybook = updatePlaybook
    this.resolveConflict = resolveConflict
    this.limits = limits
  }

  async run(inputFiles, onProgress = () => {}) {
    const files = Array.from(inputFiles || [])
    let records = files.map((file, index) => this.record(index, file.name, "waiting", {
      name: normalizePlaybookName(file.name),
    }))
    const emit = (index, state, attributes = {}) => {
      const updated = this.record(index, files[index].name, state, { ...records[index], ...attributes })
      records[index] = updated
      onProgress(updated)
      return updated
    }
    records.forEach((record) => onProgress(record))

    const batchError = this.batchError(files)
    if (batchError) {
      files.forEach((_, index) => emit(index, "failed", { errors: [batchError] }))
      return this.result(records)
    }

    let conflictPolicy = null
    const imported = new Map()

    for (const [index, file] of files.entries()) {
      emit(index, "validating", { errors: [] })
      const name = normalizePlaybookName(file.name)
      const errors = await this.fileErrors(file, name)
      if (errors.length) {
        emit(index, "failed", { name, errors })
        continue
      }

      let yaml
      try {
        yaml = await file.text()
      } catch {
        emit(index, "failed", { name, errors: ["Could not read file."] })
        continue
      }

      let validation
      try {
        validation = await this.validateYaml(yaml)
      } catch {
        emit(index, "failed", { name, errors: ["Could not validate YAML."] })
        continue
      }
      const validationErrors = validation?.valid === true || validation?.ok === true ? [] :
        this.errorList(validation?.errors, "YAML validation failed.")
      if (validationErrors.length) {
        emit(index, "failed", { name, errors: validationErrors })
        continue
      }

      let existing = imported.get(name.toLocaleLowerCase())
      if (!existing) {
        try {
          existing = await this.findByName(name)
        } catch {
          emit(index, "failed", { name, errors: ["Could not check existing playbooks."] })
          continue
        }
      }

      if (existing) {
        let decision = conflictPolicy
        if (!decision) {
          try {
            decision = await this.resolveConflict(Object.freeze({ fileName: file.name, name, existing }))
          } catch {
            emit(index, "failed", { name, errors: ["Could not resolve playbook conflict."] })
            continue
          }
          if (decision === "update_all") conflictPolicy = "update"
          if (decision === "skip_all") conflictPolicy = "skip"
        }
        if (decision === "skip" || decision === "skip_all") {
          emit(index, "skipped", { name, errors: [] })
          continue
        }
        if (decision !== "update" && decision !== "update_all") {
          emit(index, "failed", { name, errors: ["Unknown conflict decision."] })
          continue
        }

        try {
          const updated = await this.updatePlaybook(existing, { name, yaml_content: yaml })
          imported.set(name.toLocaleLowerCase(), updated || existing)
          emit(index, "updated", { name, errors: [] })
        } catch {
          emit(index, "failed", { name, errors: ["Could not update playbook."] })
        }
        continue
      }

      try {
        const created = await this.createPlaybook({ name, yaml_content: yaml })
        imported.set(name.toLocaleLowerCase(), created)
        emit(index, "imported", { name, errors: [] })
      } catch {
        emit(index, "failed", { name, errors: ["Could not create playbook."] })
      }
    }

    return this.result(records)
  }

  batchError(files) {
    if (files.length > this.limits.maxFiles) {
      return `Batch exceeds the maximum of ${this.limits.maxFiles} files.`
    }
    const bytes = files.reduce((total, file) => total + Number(file.size || 0), 0)
    if (bytes > this.limits.maxBatchBytes) {
      return `Batch exceeds the ${this.limits.maxBatchBytes}-byte limit.`
    }
    return null
  }

  async fileErrors(file, name) {
    if (!/\.ya?ml$/i.test(String(file.name || ""))) return ["Choose a .yml or .yaml file."]
    if (!name) return ["Filename does not produce a usable playbook name."]
    if (file.size > this.limits.maxFileBytes) {
      return [`File exceeds the ${this.limits.maxFileBytes}-byte limit.`]
    }
    if (!this.validateFile) return []

    try {
      const result = await this.validateFile(file, this.limits)
      if (Array.isArray(result)) return result.map(String)
      if (result?.valid === false || result?.ok === false) return this.errorList(result.errors, "File is invalid.")
      return []
    } catch {
      return ["Could not validate file."]
    }
  }

  errorList(errors, fallback) {
    return Array.isArray(errors) && errors.length ? errors.map(String) : [fallback]
  }

  record(index, fileName, state, attributes = {}) {
    return Object.freeze({
      index,
      fileName: String(fileName || ""),
      name: attributes.name || null,
      state,
      errors: Object.freeze(Array.from(attributes.errors || [])),
    })
  }

  result(records) {
    const finalRecords = Object.freeze(records.slice())
    const summary = Object.fromEntries(TERMINAL_STATES.map((state) => [
      state,
      finalRecords.filter((record) => record.state === state).length,
    ]))
    return Object.freeze({ records: finalRecords, summary: Object.freeze(summary) })
  }
}
