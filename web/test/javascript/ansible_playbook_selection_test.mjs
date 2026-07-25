import test from "node:test"
import assert from "node:assert/strict"
import {
  PlaybookSelection,
  filenameFromDisposition,
} from "../../app/javascript/lib/ansible_playbook_selection.js"

test("tracks individual selections as unique numeric ids", () => {
  const selection = new PlaybookSelection()
  selection.set(2, true)
  selection.set("2", true)
  selection.set(4, true)
  selection.set(2, false)

  assert.deepEqual(selection.ids(), [4])
})

test("select-all affects only visible rows and preserves an existing hidden selection", () => {
  const selection = new PlaybookSelection([9])
  selection.setVisible([1, 2], true)

  assert.deepEqual(selection.ids(), [9, 1, 2])
  assert.deepEqual(selection.visibleState([1, 2]), { checked: true, indeterminate: false })
  selection.setVisible([1], false)
  assert.deepEqual(selection.ids(), [9, 2])
  assert.deepEqual(selection.visibleState([1, 2]), { checked: false, indeterminate: true })
})

test("an empty visible filter is never checked or indeterminate", () => {
  const selection = new PlaybookSelection([1])
  assert.deepEqual(selection.visibleState([]), { checked: false, indeterminate: false })
})

test("derives safe server filenames from Content-Disposition", () => {
  assert.equal(
    filenameFromDisposition('attachment; filename="hunter-ansible-playbooks-20260723T120000Z.zip"'),
    "hunter-ansible-playbooks-20260723T120000Z.zip",
  )
  assert.equal(filenameFromDisposition("attachment; filename*=UTF-8''hunter%20playbooks.zip"), "hunter playbooks.zip")
  assert.equal(filenameFromDisposition("attachment"), "hunter-ansible-playbooks.zip")
  assert.equal(filenameFromDisposition('attachment; filename="../../escape.zip"'), "escape.zip")
})
