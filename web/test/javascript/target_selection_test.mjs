import test from "node:test"
import assert from "node:assert/strict"
import { TargetSelection, rangeIndices, originQuery } from "../../app/javascript/lib/target_selection.js"

test("rangeIndices returns the inclusive span in either direction", () => {
  assert.deepEqual(rangeIndices(2, 5), [2, 3, 4, 5])
  assert.deepEqual(rangeIndices(5, 2), [2, 3, 4, 5])
  assert.deepEqual(rangeIndices(3, 3), [3])
})

test("originQuery ANDs a quoted origin term onto the current query", () => {
  assert.equal(originQuery("", "https://a.example.com:443"), 'origin:"https://a.example.com:443"')
  assert.equal(originQuery("  ", "https://a.example.com:443"), 'origin:"https://a.example.com:443"')
  assert.equal(
    originQuery("status:>=500", "https://a.example.com:443"),
    'status:>=500 origin:"https://a.example.com:443"'
  )
})

test("a plain click toggles a single row and moves the anchor", () => {
  const sel = new TargetSelection({ source: "sitemap", query: "" })
  const ids = ["a", "b", "c", "d"]
  sel.applyClick(ids, 1, true, false) // tick b
  assert.deepEqual([...sel.ids], ["b"])
  assert.equal(sel.anchorIndex, 1)
  sel.applyClick(ids, 1, false, false) // untick b
  assert.deepEqual([...sel.ids], [])
})

test("shift-click fills the range to the clicked box's new state", () => {
  const sel = new TargetSelection({ source: "sitemap", query: "" })
  const ids = ["a", "b", "c", "d", "e"]
  sel.applyClick(ids, 1, true, false) // anchor at b, ticked
  const result = sel.applyClick(ids, 3, true, true) // shift to d -> b,c,d ticked
  assert.deepEqual([...sel.ids].sort(), ["b", "c", "d"])
  assert.deepEqual(result.ids.sort(), ["b", "c", "d"])
  assert.equal(result.checked, true)
  assert.equal(sel.anchorIndex, 3)
})

test("shift-click can clear a range when the clicked box is being unticked", () => {
  const sel = new TargetSelection({ source: "sitemap", query: "" })
  const ids = ["a", "b", "c", "d"]
  ids.forEach((_, i) => sel.applyClick(ids, i, true, false))
  assert.equal(sel.ids.size, 4)
  sel.applyClick(ids, 0, true, false) // re-anchor at a (still checked)
  sel.applyClick(ids, 2, false, true) // shift-unset a..c
  assert.deepEqual([...sel.ids], ["d"])
})

test("shift-click with no prior anchor behaves like a single toggle", () => {
  const sel = new TargetSelection({ source: "sitemap", query: "" })
  const ids = ["a", "b", "c"]
  sel.applyClick(ids, 2, true, true)
  assert.deepEqual([...sel.ids], ["c"])
})

test("descriptors: explicit endpoint ids produce one ids descriptor", () => {
  const sel = new TargetSelection({ source: "sitemap", query: "status:200" })
  sel.applyClick(["e1", "e2"], 0, true, false)
  sel.applyClick(["e1", "e2"], 1, true, false)
  assert.deepEqual(sel.descriptors(), [
    { source: "sitemap", mode: "ids", ids: ["e1", "e2"] },
  ])
})

test("descriptors: each ticked origin becomes a filter descriptor scoped by origin", () => {
  const sel = new TargetSelection({ source: "sitemap", query: "status:200" })
  sel.applyClick(["e1"], 0, true, false)
  sel.toggleOrigin("https://a.example.com:443", true)
  sel.toggleOrigin("https://b.example.com:80", true)
  assert.deepEqual(sel.descriptors(), [
    { source: "sitemap", mode: "ids", ids: ["e1"] },
    { source: "sitemap", mode: "filter", q: 'status:200 origin:"https://a.example.com:443"' },
    { source: "sitemap", mode: "filter", q: 'status:200 origin:"https://b.example.com:80"' },
  ])
})

test("descriptors: allMatching emits a single filter descriptor with exclusions and ignores origins", () => {
  const sel = new TargetSelection({ source: "sitemap", query: "status:200" })
  sel.toggleOrigin("https://a.example.com:443", true)
  sel.selectAllMatching()
  sel.applyClick(["e1", "e2"], 0, false, false) // exclude e1
  assert.deepEqual(sel.descriptors(), [
    { source: "sitemap", mode: "filter", q: "status:200", exclude_ids: ["e1"] },
  ])
})

test("descriptors: empty non-matching selection preserves the legacy empty-ids descriptor", () => {
  const sel = new TargetSelection({ source: "targets", query: "" })
  assert.deepEqual(sel.descriptors(), [{ source: "targets", mode: "ids", ids: [] }])
})

test("countLabel summarizes ids, origins, and all-matching states", () => {
  const sel = new TargetSelection({ source: "sitemap", query: "" })
  assert.equal(sel.countLabel(), "0")
  sel.applyClick(["e1", "e2"], 0, true, false)
  assert.equal(sel.countLabel(), "1")
  sel.applyClick(["e1", "e2"], 1, true, false)
  sel.toggleOrigin("https://a.example.com:443", true)
  assert.equal(sel.countLabel(), "2 + 1 origin")
  sel.toggleOrigin("https://b.example.com:80", true)
  assert.equal(sel.countLabel(), "2 + 2 origins")
  sel.selectAllMatching()
  assert.equal(sel.countLabel(), "all matching − 0")
})

test("clear resets every part of the selection", () => {
  const sel = new TargetSelection({ source: "sitemap", query: "" })
  sel.applyClick(["e1"], 0, true, false)
  sel.toggleOrigin("https://a.example.com:443", true)
  sel.selectAllMatching()
  sel.clear()
  assert.equal(sel.allMatching, false)
  assert.equal(sel.ids.size, 0)
  assert.equal(sel.origins.size, 0)
  assert.equal(sel.excluded.size, 0)
  assert.equal(sel.anchorIndex, null)
  assert.deepEqual(sel.descriptors(), [{ source: "sitemap", mode: "ids", ids: [] }])
})
