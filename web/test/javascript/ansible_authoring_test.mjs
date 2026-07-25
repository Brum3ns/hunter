import test from "node:test"
import assert from "node:assert/strict"
import {
  acceptsYamlFilename,
  downloadFilename,
  fileValidationErrors,
  nextDirtyState,
  normalizeApiErrors,
} from "../../app/javascript/lib/ansible_authoring.js"

test("accepts YAML filename extensions case-insensitively and only at the end", () => {
  for (const name of ["baseline.yml", "inventory.yaml", "UPPER.YML", "mixed.YaMl"]) {
    assert.equal(acceptsYamlFilename(name), true, name)
  }
  for (const name of ["notes.txt", "playbook.yaml.exe", ".yaml-backup", "yaml"]) {
    assert.equal(acceptsYamlFilename(name), false, name)
  }
})

test("builds a path-safe deterministic YAML download filename", () => {
  assert.equal(downloadFilename("  Worker baseline / prod  "), "Worker-baseline-prod.yml")
  assert.equal(downloadFilename("../../.ssh/id_rsa"), "ssh-id_rsa.yml")
  assert.equal(downloadFilename("already.YAML"), "already.yml")
  assert.equal(downloadFilename("///"), "ansible-resource.yml")
})

test("checks extension and Blob byte size before a file is read", () => {
  const valid = new Blob(["é"])
  Object.defineProperty(valid, "name", { value: "worker.yml" })
  assert.equal(valid.size, 2)
  assert.deepEqual(fileValidationErrors(valid, 2), [])
  assert.deepEqual(fileValidationErrors(valid, 1), ["File exceeds the 1-byte limit."])

  const wrong = new Blob(["---\n"])
  Object.defineProperty(wrong, "name", { value: "worker.txt" })
  assert.deepEqual(fileValidationErrors(wrong, 100), ["Choose a .yml or .yaml file."])
})

test("dirty state changes only for explicit editor lifecycle events", () => {
  assert.equal(nextDirtyState(false, "edit"), true)
  assert.equal(nextDirtyState(true, "edit"), true)
  assert.equal(nextDirtyState(true, "saved"), false)
  assert.equal(nextDirtyState(true, "loaded"), false)
  assert.equal(nextDirtyState(false, "unknown"), false)
})

test("normalizes validation envelopes and transport failures into text messages", () => {
  assert.deepEqual(normalizeApiErrors({ details: { name: ["can't be blank"], yaml_content: ["is unsafe"] } }), [
    "name can't be blank",
    "yaml_content is unsafe",
  ])
  assert.deepEqual(normalizeApiErrors({ detail: ["one", "two"] }), ["one", "two"])
  assert.deepEqual(normalizeApiErrors({ errors: ["invalid YAML"] }), ["invalid YAML"])
  assert.deepEqual(normalizeApiErrors(null), ["Request failed."])
})
