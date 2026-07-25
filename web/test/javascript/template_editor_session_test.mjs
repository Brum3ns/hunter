import test from "node:test"
import assert from "node:assert/strict"
import { TemplateEditorSession } from "../../app/javascript/lib/template_editor_session.js"

test("starts as a clean blank editor", () => {
  const session = new TemplateEditorSession()
  assert.equal(session.editingId, null)
  assert.equal(session.dirty, false)
  assert.equal(session.isEditing(1), false)
})

test("markDirty requires confirmation before replacement", () => {
  const session = new TemplateEditorSession()
  session.markDirty()
  let prompts = 0
  assert.equal(session.mayReplace(() => { prompts += 1; return false }), false)
  assert.equal(session.dirty, true)
  assert.equal(session.mayReplace(() => { prompts += 1; return true }), true)
  assert.equal(session.dirty, true)
  assert.equal(prompts, 2)
})

test("clean sessions replace without invoking confirmation", () => {
  const session = new TemplateEditorSession()
  session.markClean(12)
  assert.equal(session.mayReplace(() => { throw new Error("must not prompt") }), true)
  assert.equal(session.isEditing("12"), true)
})

test("save and reset establish new clean identities", () => {
  const session = new TemplateEditorSession()
  session.markDirty()
  session.markClean(42)
  assert.equal(session.editingId, 42)
  assert.equal(session.dirty, false)
  session.markDirty()
  session.markClean(null)
  assert.equal(session.editingId, null)
  assert.equal(session.dirty, false)
})
