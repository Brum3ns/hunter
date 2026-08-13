import test from "node:test"
import assert from "node:assert/strict"
import {
  loadHistoryRailCollapsed,
  saveHistoryRailCollapsed,
} from "../../app/javascript/lib/assistant_history_rail.js"

function store(raw) {
  return {
    key: null,
    getItem(key) { this.key = key; return raw },
  }
}

function recordingStorage() {
  return {
    key: null,
    value: null,
    setItem(key, value) { this.key = key; this.value = value },
  }
}

test("history rail accepts only one boolean field", () => {
  const valid = store('{"collapsed":true}')
  assert.equal(loadHistoryRailCollapsed(valid), true)
  assert.equal(valid.key, "hunter:assistant-history-rail:v1")
  for (const raw of [null, "{}", '{"collapsed":1}', '{"collapsed":true,"id":7}', "bad"]) {
    assert.equal(loadHistoryRailCollapsed(store(raw)), false)
  }
})

test("history rail persists only the closed boolean shape", () => {
  const storage = recordingStorage()
  saveHistoryRailCollapsed(storage, true)
  assert.equal(storage.key, "hunter:assistant-history-rail:v1")
  assert.deepEqual(JSON.parse(storage.value), { collapsed: true })

  saveHistoryRailCollapsed(storage, false)
  assert.equal(storage.key, "hunter:assistant-history-rail:v1")
  assert.deepEqual(JSON.parse(storage.value), { collapsed: false })
})

test("history rail tolerates unavailable storage", () => {
  const storage = {
    getItem() { throw new Error("denied") },
    setItem() { throw new Error("denied") },
  }

  assert.equal(loadHistoryRailCollapsed(storage), false)
  assert.doesNotThrow(() => saveHistoryRailCollapsed(storage, true))
})
