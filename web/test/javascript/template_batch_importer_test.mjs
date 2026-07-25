import test from "node:test"
import assert from "node:assert/strict"
import { TemplateBatchImporter } from "../../app/javascript/lib/template_batch_importer.js"

function file(name, yaml, { size = Buffer.byteLength(yaml), readError = false } = {}) {
  return {
    name,
    size,
    async text() {
      if (readError) throw new Error("disk read failed")
      return yaml
    },
  }
}

function templateName(yaml) {
  return yaml.match(/^name:\s*(\S+)/m)?.[1]
}

function importer(overrides = {}) {
  let nextId = 100
  return new TemplateBatchImporter({
    maxBytes: 64000,
    validateYaml: async (yaml) => {
      if (yaml.includes("INVALID")) return { ok: false, errors: ["bad yaml"] }
      return { ok: true, template: { name: templateName(yaml) } }
    },
    createTemplate: async (yaml) => ({
      ok: true,
      template: { id: nextId++, name: templateName(yaml) },
    }),
    updateTemplate: async (id, yaml) => ({
      ok: true,
      template: { id, name: templateName(yaml) },
    }),
    resolveConflict: async () => "skip",
    onStatus: () => {},
    ...overrides,
  })
}

test("imports several unique files as separate templates in selection order", async () => {
  const created = []
  const statuses = []
  const subject = importer({
    createTemplate: async (yaml) => {
      created.push(templateName(yaml))
      return { ok: true, template: { id: created.length, name: templateName(yaml) } }
    },
    onStatus: (result) => statuses.push(`${result.fileName}:${result.status}`),
  })

  const results = await subject.run([
    file("alpha.yaml", "name: alpha\ncommands: []\n"),
    file("beta.yml", "name: beta\ncommands: []\n"),
  ], [])

  assert.deepEqual(created, ["alpha", "beta"])
  assert.deepEqual(results.map(({ fileName, templateName, status }) => ({ fileName, templateName, status })), [
    { fileName: "alpha.yaml", templateName: "alpha", status: "imported" },
    { fileName: "beta.yml", templateName: "beta", status: "imported" },
  ])
  assert.deepEqual(statuses, [
    "alpha.yaml:waiting", "beta.yml:waiting",
    "alpha.yaml:validating", "alpha.yaml:imported",
    "beta.yml:validating", "beta.yml:imported",
  ])
})

test("file and validation failures do not stop later imports", async () => {
  const created = []
  const results = await importer({
    createTemplate: async (yaml) => {
      created.push(templateName(yaml))
      return { ok: true, template: { id: 1, name: templateName(yaml) } }
    },
  }).run([
    file("notes.txt", "name: notes"),
    file("huge.yaml", "name: huge", { size: 64001 }),
    file("unreadable.yml", "name: unreadable", { readError: true }),
    file("invalid.yaml", "INVALID"),
    file("good.YML", "name: good\ncommands: []\n"),
  ], [])

  assert.deepEqual(results.map((result) => result.status), ["failed", "failed", "failed", "failed", "imported"])
  assert.match(results[0].errors[0], /\.yaml and \.yml/)
  assert.match(results[1].errors[0], /64 KB/)
  assert.equal(results[2].errors[0], "Could not read file.")
  assert.deepEqual(results[3].errors, ["bad yaml"])
  assert.deepEqual(created, ["good"])
})

test("update and skip resolve individual conflicts independently", async () => {
  const decisions = ["update", "skip"]
  const prompts = []
  const updated = []
  const subject = importer({
    resolveConflict: async (conflict) => {
      prompts.push(conflict.templateName)
      return decisions.shift()
    },
    updateTemplate: async (id, yaml) => {
      updated.push(id)
      return { ok: true, template: { id, name: templateName(yaml) } }
    },
  })

  const results = await subject.run([
    file("alpha.yaml", "name: alpha"),
    file("beta.yaml", "name: beta"),
  ], [{ id: 10, name: "alpha" }, { id: 20, name: "beta" }])

  assert.deepEqual(prompts, ["alpha", "beta"])
  assert.deepEqual(updated, [10])
  assert.deepEqual(results.map((result) => result.status), ["updated", "skipped"])
})

for (const policy of ["update_all", "skip_all"]) {
  test(`${policy} applies to every remaining conflict without another prompt`, async () => {
    let promptCount = 0
    const updated = []
    const subject = importer({
      resolveConflict: async () => { promptCount += 1; return policy },
      updateTemplate: async (id, yaml) => {
        updated.push(id)
        return { ok: true, template: { id, name: templateName(yaml) } }
      },
    })

    const results = await subject.run([
      file("alpha.yaml", "name: alpha"),
      file("beta.yaml", "name: beta"),
    ], [{ id: 10, name: "alpha" }, { id: 20, name: "beta" }])

    assert.equal(promptCount, 1)
    assert.deepEqual(
      results.map((result) => result.status),
      policy === "update_all" ? ["updated", "updated"] : ["skipped", "skipped"],
    )
    assert.deepEqual(updated, policy === "update_all" ? [10, 20] : [])
  })
}

test("a duplicate name created earlier in the batch becomes a conflict", async () => {
  const updated = []
  let prompt
  const subject = importer({
    createTemplate: async (yaml) => ({ ok: true, template: { id: 77, name: templateName(yaml) } }),
    resolveConflict: async (conflict) => { prompt = conflict; return "update" },
    updateTemplate: async (id, yaml) => {
      updated.push(id)
      return { ok: true, template: { id, name: templateName(yaml) } }
    },
  })

  const results = await subject.run([
    file("first.yaml", "name: repeated"),
    file("second.yaml", "name: repeated"),
  ], [])

  assert.equal(prompt.existing.id, 77)
  assert.deepEqual(updated, [77])
  assert.deepEqual(results.map((result) => result.status), ["imported", "updated"])
})

test("create and update callback failures remain per-file results", async () => {
  const subject = importer({
    createTemplate: async () => ({ ok: false, errors: ["create rejected"] }),
    resolveConflict: async () => "update",
    updateTemplate: async () => { throw new Error("network gone") },
  })

  const results = await subject.run([
    file("new.yaml", "name: new"),
    file("old.yaml", "name: old"),
  ], [{ id: 9, name: "old" }])

  assert.deepEqual(results.map((result) => result.status), ["failed", "failed"])
  assert.deepEqual(results[0].errors, ["create rejected"])
  assert.deepEqual(results[1].errors, ["Update failed."])
})

test("a conflict resolver failure does not stop later files", async () => {
  const created = []
  const subject = importer({
    resolveConflict: async () => { throw new Error("dialog disappeared") },
    createTemplate: async (yaml) => {
      created.push(templateName(yaml))
      return { ok: true, template: { id: 42, name: templateName(yaml) } }
    },
  })

  const results = await subject.run([
    file("old.yaml", "name: old"),
    file("new.yaml", "name: new"),
  ], [{ id: 9, name: "old" }])

  assert.deepEqual(results.map((result) => result.status), ["failed", "imported"])
  assert.deepEqual(results[0].errors, ["Could not resolve template conflict."])
  assert.deepEqual(created, ["new"])
})
