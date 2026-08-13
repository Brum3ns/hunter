import test from "node:test"
import assert from "node:assert/strict"
import {
  changeFontScale,
  DEFAULT_FONT_SCALE_INDEX,
  FONT_SCALE_STORAGE_KEY,
  FONT_SCALES,
  loadFontScaleIndex,
  saveFontScaleIndex,
} from "../../app/javascript/lib/assistant_font_scale.js"

test("font scale exposes only the four approved levels", () => {
  assert.deepEqual([...FONT_SCALES], [0.875, 1, 1.125, 1.25])
  assert.equal(DEFAULT_FONT_SCALE_INDEX, 1)
  assert.deepEqual(changeFontScale(1, 1), { index: 2, value: 1.125 })
  assert.deepEqual(changeFontScale(2, -1), { index: 1, value: 1 })
  assert.deepEqual(changeFontScale(0, -1), { index: 0, value: 0.875 })
  assert.deepEqual(changeFontScale(3, 1), { index: 3, value: 1.25 })
  assert.deepEqual(changeFontScale(99, 1), { index: 2, value: 1.125 })
})

test("font scale storage accepts only a closed in-range integer shape", () => {
  const values = new Map([[FONT_SCALE_STORAGE_KEY, JSON.stringify({ index: 3 })]])
  const storage = {
    getItem(key) { return values.get(key) ?? null },
    setItem(key, value) { values.set(key, value) },
  }

  assert.equal(loadFontScaleIndex(storage), 3)
  assert.equal(saveFontScaleIndex(storage, 0), true)
  assert.deepEqual(JSON.parse(values.get(FONT_SCALE_STORAGE_KEY)), { index: 0 })

  for (const value of [
    "not-json",
    JSON.stringify({}),
    JSON.stringify({ index: 1, body: "must reject" }),
    JSON.stringify({ index: "1" }),
    JSON.stringify({ index: -1 }),
    JSON.stringify({ index: 4 }),
  ]) {
    values.set(FONT_SCALE_STORAGE_KEY, value)
    assert.equal(loadFontScaleIndex(storage), DEFAULT_FONT_SCALE_INDEX)
  }
  assert.equal(saveFontScaleIndex(storage, 4), false)
  assert.equal(saveFontScaleIndex(storage, 1.5), false)
})

test("unavailable storage falls back without throwing", () => {
  const storage = {
    getItem() { throw new Error("denied") },
    setItem() { throw new Error("denied") },
  }

  assert.equal(loadFontScaleIndex(storage), DEFAULT_FONT_SCALE_INDEX)
  assert.equal(saveFontScaleIndex(storage, 2), false)
  assert.equal(loadFontScaleIndex(null), DEFAULT_FONT_SCALE_INDEX)
})
