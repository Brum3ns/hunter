import test from "node:test"
import assert from "node:assert/strict"
import {
  DEFAULT_PANEL_SIZE,
  PANEL_SIZE_STORAGE_KEY,
  clampPanelSize,
  desktopPanel,
  loadPanelSize,
  resizeFromKeyboard,
  resizeFromPointer,
  savePanelSize,
} from "../../app/javascript/lib/assistant_panel_size.js"

const viewport = { width: 1440, height: 1000 }

test("desktop sizing uses the responsive breakpoint and visible viewport bounds", () => {
  assert.equal(desktopPanel({ width: 639, height: 900 }), false)
  assert.equal(desktopPanel({ width: 640, height: 900 }), true)
  assert.deepEqual(clampPanelSize(DEFAULT_PANEL_SIZE, viewport), { width: 680, height: 780 })
  assert.deepEqual(
    clampPanelSize({ width: 1, height: 9999 }, viewport),
    { width: 480, height: 968 },
  )
  assert.deepEqual(
    clampPanelSize(DEFAULT_PANEL_SIZE, { width: 900, height: 480 }),
    { width: 680, height: 448 },
  )
})

test("top-left pointer movement resizes while the bottom-right corner stays anchored", () => {
  assert.deepEqual(
    resizeFromPointer(
      { width: 680, height: 780 },
      { x: 400, y: 300 },
      { x: 336, y: 252 },
      viewport,
    ),
    { width: 744, height: 828 },
  )
  assert.deepEqual(
    resizeFromPointer(
      { width: 680, height: 780 },
      { x: 400, y: 300 },
      { x: 9999, y: 9999 },
      viewport,
    ),
    { width: 480, height: 520 },
  )
})

test("keyboard arrows grow toward top-left and shrink toward bottom-right", () => {
  assert.deepEqual(
    resizeFromKeyboard({ width: 680, height: 780 }, "ArrowLeft", 16, viewport),
    { width: 696, height: 780 },
  )
  assert.deepEqual(
    resizeFromKeyboard({ width: 680, height: 780 }, "ArrowDown", 48, viewport),
    { width: 680, height: 732 },
  )
  assert.equal(resizeFromKeyboard(DEFAULT_PANEL_SIZE, "Enter", 16, viewport), null)
})

test("storage accepts only the closed numeric shape and clamps restored values", () => {
  const values = new Map([
    [PANEL_SIZE_STORAGE_KEY, JSON.stringify({ width: 900, height: 900 })],
  ])
  const storage = {
    getItem: (key) => values.get(key),
    setItem: (key, value) => values.set(key, value),
  }

  assert.deepEqual(loadPanelSize(storage, viewport), { width: 900, height: 900 })

  values.set(
    PANEL_SIZE_STORAGE_KEY,
    JSON.stringify({ width: 900, height: 900, message: "must reject" }),
  )
  assert.deepEqual(loadPanelSize(storage, viewport), DEFAULT_PANEL_SIZE)

  values.set(PANEL_SIZE_STORAGE_KEY, JSON.stringify({ width: "900", height: 900 }))
  assert.deepEqual(loadPanelSize(storage, viewport), DEFAULT_PANEL_SIZE)

  values.set(PANEL_SIZE_STORAGE_KEY, JSON.stringify({ width: 4000, height: 4000 }))
  assert.deepEqual(loadPanelSize(storage, viewport), { width: 1408, height: 968 })

  assert.equal(savePanelSize(storage, { width: 720, height: 760 }), true)
  assert.deepEqual(
    JSON.parse(values.get(PANEL_SIZE_STORAGE_KEY)),
    { width: 720, height: 760 },
  )
})

test("malformed data and unavailable storage fall back without throwing", () => {
  const malformed = {
    getItem() { return "not-json" },
    setItem() {},
  }
  const broken = {
    getItem() { throw new Error("denied") },
    setItem() { throw new Error("denied") },
  }

  assert.deepEqual(loadPanelSize(malformed, viewport), DEFAULT_PANEL_SIZE)
  assert.deepEqual(loadPanelSize(broken, viewport), DEFAULT_PANEL_SIZE)
  assert.equal(savePanelSize(broken, DEFAULT_PANEL_SIZE), false)
})
