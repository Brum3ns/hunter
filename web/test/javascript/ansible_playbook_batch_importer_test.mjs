import test from "node:test"
import assert from "node:assert/strict"
import {
  AnsiblePlaybookBatchImporter,
  normalizePlaybookName,
} from "../../app/javascript/lib/ansible_playbook_batch_importer.js"

const LIMITS = { maxFiles: 3, maxFileBytes: 64, maxBatchBytes: 128 }

function file(name, yaml, { size = Buffer.byteLength(yaml), readError = false } = {}) {
  return {
    name,
    size,
    async text() {
      if (readError) throw new Error("read failed")
      return yaml
    },
  }
}

function subject(overrides = {}) {
  let nextId = 100
  const stored = []
  return new AnsiblePlaybookBatchImporter({
    validateFile: () => [],
    validateYaml: async () => ({ valid: true, errors: [] }),
    findByName: async (name) => stored.find((item) => item.name.toLowerCase() === name.toLowerCase()) || null,
    createPlaybook: async (attributes) => {
      const created = { id: nextId++, ...attributes }
      stored.push(created)
      return created
    },
    updatePlaybook: async (existing, attributes) => Object.assign(existing, attributes),
    resolveConflict: async () => "skip",
    limits: LIMITS,
    ...overrides,
  })
}

test("derives safe names from case-insensitive YAML filenames", () => {
  assert.equal(normalizePlaybookName("Worker baseline.YML"), "Worker-baseline")
  assert.equal(normalizePlaybookName("prod.api.yaml"), "prod.api")
  assert.equal(normalizePlaybookName("../../.yaml"), null)
  assert.equal(normalizePlaybookName("playbook.yaml.exe"), null)
})

test("processes valid files sequentially and emits immutable progress", async () => {
  const order = []
  const progress = []
  const importer = subject({
    validateYaml: async (yaml) => { order.push(`validate:${yaml}`); return { valid: true, errors: [] } },
    createPlaybook: async ({ name, yaml_content }) => {
      order.push(`create:${name}`)
      return { id: order.length, name, yaml_content }
    },
  })

  const result = await importer.run([
    file("first.yml", "first"),
    file("second.YAML", "second"),
  ], (record) => {
    progress.push(record)
    assert.equal(Object.isFrozen(record), true)
    assert.equal(Object.isFrozen(record.errors), true)
  })

  assert.deepEqual(order, ["validate:first", "create:first", "validate:second", "create:second"])
  assert.deepEqual(result.records.map(({ name, state }) => ({ name, state })), [
    { name: "first", state: "imported" },
    { name: "second", state: "imported" },
  ])
  assert.deepEqual(progress.map(({ fileName, state }) => `${fileName}:${state}`), [
    "first.yml:waiting", "second.YAML:waiting",
    "first.yml:validating", "first.yml:imported",
    "second.YAML:validating", "second.YAML:imported",
  ])
  assert.deepEqual(result.summary, { imported: 2, updated: 0, skipped: 0, failed: 0 })
})

test("rejects extension, file size, read, and validation failures while continuing", async () => {
  const created = []
  const result = await subject({
    validateYaml: async (yaml) => yaml === "bad" ? { valid: false, errors: ["unsafe YAML"] } : { valid: true, errors: [] },
    createPlaybook: async (attributes) => { created.push(attributes.name); return { id: 1, ...attributes } },
  }).run([
    file("notes.txt", "notes"),
    file("large.yml", "large", { size: 65 }),
    file("unreadable.yml", "ignored", { readError: true }),
  ], () => {})

  assert.deepEqual(result.records.map((record) => record.state), ["failed", "failed", "failed"])
  assert.match(result.records[0].errors[0], /\.yml or \.yaml/)
  assert.match(result.records[1].errors[0], /64-byte limit/)
  assert.equal(result.records[2].errors[0], "Could not read file.")
  assert.deepEqual(created, [])

  const continued = await subject({
    validateYaml: async (yaml) => yaml === "bad" ? { valid: false, errors: ["unsafe YAML"] } : { valid: true, errors: [] },
    createPlaybook: async (attributes) => { created.push(attributes.name); return { id: 2, ...attributes } },
  }).run([file("bad.yml", "bad"), file("good.yml", "good")], () => {})
  assert.deepEqual(continued.records.map((record) => record.state), ["failed", "imported"])
  assert.deepEqual(created, ["good"])
})

test("rejects over-count and over-byte batches before reading files", async () => {
  let reads = 0
  const files = Array.from({ length: 4 }, (_, index) => ({
    ...file(`${index}.yml`, "x"),
    async text() { reads += 1; return "x" },
  }))
  const countResult = await subject().run(files, () => {})

  assert.equal(reads, 0)
  assert.equal(countResult.summary.failed, 4)
  assert.match(countResult.records[0].errors[0], /maximum of 3 files/)

  const byteResult = await subject().run([
    file("one.yml", "x", { size: 64 }),
    file("two.yml", "x", { size: 64 }),
    file("three.yml", "x", { size: 1 }),
  ], () => {})
  assert.equal(byteResult.summary.failed, 3)
  assert.match(byteResult.records[0].errors[0], /128-byte limit/)
})

test("supports per-conflict update and skip decisions", async () => {
  const existing = [{ id: 1, name: "update-me" }, { id: 2, name: "skip-me" }]
  const updated = []
  const decisions = ["update", "skip"]
  const result = await subject({
    findByName: async (name) => existing.find((item) => item.name === name),
    resolveConflict: async () => decisions.shift(),
    updatePlaybook: async (record, attributes) => { updated.push(record.id); return { ...record, ...attributes } },
  }).run([file("update-me.yml", "new-a"), file("skip-me.yml", "new-b")], () => {})

  assert.deepEqual(result.records.map((record) => record.state), ["updated", "skipped"])
  assert.deepEqual(updated, [1])
  assert.deepEqual(result.summary, { imported: 0, updated: 1, skipped: 1, failed: 0 })
})

for (const policy of ["update_all", "skip_all"]) {
  test(`${policy} applies only within one run`, async () => {
    let prompts = 0
    const existing = [{ id: 1, name: "one" }, { id: 2, name: "two" }]
    const importer = subject({
      findByName: async (name) => existing.find((item) => item.name === name),
      resolveConflict: async () => { prompts += 1; return policy },
    })

    const first = await importer.run([file("one.yml", "a"), file("two.yml", "b")], () => {})
    assert.equal(prompts, 1)
    assert.deepEqual(first.records.map((record) => record.state),
      policy === "update_all" ? ["updated", "updated"] : ["skipped", "skipped"])

    await importer.run([file("one.yml", "again")], () => {})
    assert.equal(prompts, 2)
  })
}

test("a later duplicate derived name can update the earlier imported playbook", async () => {
  let existing = null
  const writes = []
  const result = await subject({
    findByName: async () => existing,
    createPlaybook: async (attributes) => {
      existing = { id: 77, ...attributes }
      writes.push(attributes.yaml_content)
      return existing
    },
    resolveConflict: async () => "update",
    updatePlaybook: async (record, attributes) => {
      Object.assign(record, attributes)
      writes.push(attributes.yaml_content)
      return record
    },
  }).run([file("same.yml", "first"), file("same.YAML", "second")], () => {})

  assert.deepEqual(result.records.map((record) => record.state), ["imported", "updated"])
  assert.deepEqual(writes, ["first", "second"])
  assert.equal(existing.yaml_content, "second")
})

test("network exceptions become per-file failures without YAML in the error", async () => {
  const result = await subject({
    createPlaybook: async ({ yaml_content }) => { throw new Error(`failed with ${yaml_content}`) },
  }).run([file("secret.yml", "literal-secret"), file("next.yml", "next-secret")], () => {})

  assert.deepEqual(result.records.map((record) => record.state), ["failed", "failed"])
  assert.deepEqual(result.summary, { imported: 0, updated: 0, skipped: 0, failed: 2 })
  refuteYaml(result.records, "literal-secret")
  refuteYaml(result.records, "next-secret")
})

function refuteYaml(records, yaml) {
  assert.equal(JSON.stringify(records).includes(yaml), false)
}
