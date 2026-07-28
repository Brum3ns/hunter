import test from "node:test"
import assert from "node:assert/strict"
import { filterTemplates, parseTemplateQuery } from "../../app/javascript/lib/template_search.js"

const templates = [
  {
    id: 1,
    name: "nuclei-cve",
    kind: "cmdscript",
    description: "Scan remote code execution signatures",
    tags: ["cve", "network"],
    created_by: "alice",
    commands: [{ command: "nuclei", args: ["-tags", "cve"] }],
  },
  {
    id: 2,
    name: "http-probe",
    kind: "workflow",
    description: "owner:alice compatibility probe",
    tags: ["http"],
    created_by: "bob",
    commands: [{ command: "httpx", args: [["-silent"], ["-status-code"]] }],
  },
  {
    id: 3,
    name: "dns-enum",
    kind: "cmdscript",
    description: "Enumerate DNS records",
    tags: ["network"],
    created_by: "carol",
    commands: [{ command: "dnsx", args: ["-resp"] }],
  },
]

const ids = (query) => filterTemplates(templates, query).map((template) => template.id)

test("plain text searches names, descriptions, tags, commands, and arguments", () => {
  assert.deepEqual(ids("nuclei"), [1])
  assert.deepEqual(ids("remote code"), [1])
  assert.deepEqual(ids("network"), [1, 3])
  assert.deepEqual(ids("httpx"), [2])
  assert.deepEqual(ids("status-code"), [2])
})

test("supported dorks use their documented matching semantics", () => {
  assert.deepEqual(ids("name:cve"), [1])
  assert.deepEqual(ids("name:http-*"), [2])
  assert.deepEqual(ids("kind:workflow"), [2])
  assert.deepEqual(ids("tag:network"), [1, 3])
  assert.deepEqual(ids("command:nuclei"), [1])
  assert.deepEqual(ids('command:"httpx -silent"'), [2])
  assert.deepEqual(ids("creator:ALICE"), [1])
})

test("AND binds tighter than OR and parentheses override precedence", () => {
  assert.deepEqual(ids("tag:cve OR tag:http AND kind:cmdscript"), [1])
  assert.deepEqual(ids("(tag:cve OR tag:http) AND kind:cmdscript"), [1])
  assert.deepEqual(ids("kind:cmdscript tag:network"), [1, 3])
  assert.deepEqual(ids("kind:workflow OR creator:carol"), [2, 3])
})

test("quotes, case folding, and escaped wildcard input are safe", () => {
  assert.deepEqual(ids('"remote code"'), [1])
  assert.deepEqual(ids("NAME:NUCLEI-*"), [1])
  assert.deepEqual(ids("name:*probe"), [2])
  assert.doesNotThrow(() => ids("name:[*"))
})

test("unknown dorks remain literal text", () => {
  assert.deepEqual(ids("owner:alice"), [2])
})

test("malformed expressions fall back without throwing", () => {
  for (const query of ['name:"nuclei', "(tag:cve", "tag:cve OR", "AND tag:cve"]) {
    assert.doesNotThrow(() => filterTemplates(templates, query), query)
  }
})

test("blank filtering preserves order without mutating the source array", () => {
  const original = [...templates]
  const result = filterTemplates(templates, "")
  assert.deepEqual(result.map((template) => template.id), [1, 2, 3])
  assert.notEqual(result, templates)
  assert.deepEqual(templates, original)
})

test("the parser exposes a stable expression shape", () => {
  assert.deepEqual(parseTemplateQuery("name:nuclei tag:cve OR creator:bob"), {
    type: "or",
    children: [
      {
        type: "and",
        children: [
          { type: "term", key: "name", value: "nuclei" },
          { type: "term", key: "tag", value: "cve" },
        ],
      },
      { type: "term", key: "creator", value: "bob" },
    ],
  })
})
