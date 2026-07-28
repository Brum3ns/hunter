import test from "node:test"
import assert from "node:assert/strict"
import { PollFailures, terminalRunStatus } from "../../app/javascript/lib/ansible_run_polling.js"

test("recognizes only explicit terminal run-group states", () => {
  for (const status of ["succeeded", "failed", "partially_succeeded", "canceled"]) {
    assert.equal(terminalRunStatus(status), true, status)
  }
  for (const status of ["queued", "running", "canceling", "unknown"]) {
    assert.equal(terminalRunStatus(status), false, status)
  }
})

test("stops after repeated network failures and resets after success", () => {
  const failures = new PollFailures(3)

  assert.equal(failures.recordFailure(), false)
  assert.equal(failures.recordFailure(), false)
  assert.equal(failures.recordFailure(), true)
  failures.recordSuccess()
  assert.equal(failures.count, 0)
  assert.equal(failures.recordFailure(), false)
})
