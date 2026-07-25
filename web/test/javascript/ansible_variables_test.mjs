import test from "node:test"
import assert from "node:assert/strict"
import { formTypedValue, variablePayload } from "../../app/javascript/lib/ansible_variables.js"

test("normalizes scalar form values without coercing arbitrary booleans", () => {
  assert.equal(formTypedValue("string", " 001 "), " 001 ")
  assert.equal(formTypedValue("number", "42.5"), 42.5)
  assert.equal(formTypedValue("boolean", "true"), true)
  assert.equal(formTypedValue("boolean", "false"), false)
  assert.equal(formTypedValue("boolean", "yes"), "yes")
})

test("leaves list and dictionary fragments for the safe server boundary", () => {
  assert.equal(formTypedValue("list", "- one\n- two\n"), "- one\n- two\n")
  assert.equal(formTypedValue("dictionary", "region: eu\n"), "region: eu\n")
})

test("omits a blank configured secret while retaining a replacement", () => {
  const base = { name: "token", valueType: "string", secret: true, configured: true }

  assert.deepEqual(variablePayload({ ...base, rawValue: "" }, 2), {
    name: "token", value_type: "string", secret: true, position: 2,
  })
  assert.deepEqual(variablePayload({ ...base, rawValue: "replacement" }, 2), {
    name: "token", value_type: "string", secret: true, position: 2, value: "replacement",
  })
})
