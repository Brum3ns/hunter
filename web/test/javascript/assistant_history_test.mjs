import test from "node:test"
import assert from "node:assert/strict"
import {
  conversationIds,
  moveConversation,
  reorderConversation,
} from "../../app/javascript/lib/assistant_history.js"

const conversations = () => [{ id: 1 }, { id: "2" }, { id: 3 }]

test("drag reorder inserts before or after without mutating the source", () => {
  const source = conversations()

  const before = reorderConversation(source, 3, "2", "before")
  const after = reorderConversation(source, 1, 3, "after")

  assert.deepEqual(before.map((item) => item.id), [1, 3, "2"])
  assert.deepEqual(after.map((item) => item.id), ["2", 3, 1])
  assert.deepEqual(source.map((item) => item.id), [1, "2", 3])
  assert.notEqual(before, source)
})

test("drag reorder treats numeric and string IDs consistently", () => {
  assert.deepEqual(
    reorderConversation(conversations(), "1", 3, "before").map((item) => item.id),
    ["2", 1, 3],
  )
  assert.deepEqual(
    reorderConversation(conversations(), 2, "1", "after").map((item) => item.id),
    [1, "2", 3],
  )
})

test("drag reorder is a no-op for invalid or identical targets", () => {
  for (const args of [
    [9, 1, "before"],
    [1, 9, "after"],
    [1, 1, "after"],
    [1, 3, "sideways"],
  ]) {
    assert.deepEqual(
      reorderConversation(conversations(), ...args).map((item) => item.id),
      [1, "2", 3],
    )
  }
})

test("discrete movement supports only one bounded step", () => {
  assert.deepEqual(moveConversation(conversations(), 2, -1).map((item) => item.id), ["2", 1, 3])
  assert.deepEqual(moveConversation(conversations(), "2", 1).map((item) => item.id), [1, 3, "2"])
  assert.deepEqual(moveConversation(conversations(), 1, -1).map((item) => item.id), [1, "2", 3])
  assert.deepEqual(moveConversation(conversations(), 3, 1).map((item) => item.id), [1, "2", 3])
  assert.deepEqual(moveConversation(conversations(), 2, 4).map((item) => item.id), [1, "2", 3])
})

test("conversationIds preserves the authoritative visible order", () => {
  assert.deepEqual(conversationIds(conversations()), [1, "2", 3])
})
