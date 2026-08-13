import test from "node:test"
import assert from "node:assert/strict"
import {
  loadHistoryRailCollapsed,
  saveHistoryRailCollapsed,
} from "../../app/javascript/lib/assistant_history_rail.js"

function store(raw) {
  return { getItem() { return raw } }
}

function recordingStorage() {
  return {
    value: null,
    setItem(_key, value) { this.value = value },
  }
}

test("history rail accepts only one boolean field", () => {
  assert.equal(loadHistoryRailCollapsed(store('{"collapsed":true}')), true)
  for (const raw of [null, "{}", '{"collapsed":1}', '{"collapsed":true,"id":7}', "bad"]) {
    assert.equal(loadHistoryRailCollapsed(store(raw)), false)
  }
})

test("history rail persists only the closed boolean shape", () => {
  const storage = recordingStorage()
  saveHistoryRailCollapsed(storage, true)
  assert.deepEqual(JSON.parse(storage.value), { collapsed: true })
})
