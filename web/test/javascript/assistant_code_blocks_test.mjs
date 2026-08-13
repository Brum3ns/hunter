import test from "node:test"
import assert from "node:assert/strict"
import { register } from "node:module"
import { JSDOM } from "jsdom"

const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  url: "https://hunter.test/",
})
globalThis.window = dom.window
globalThis.document = dom.window.document
register("./support/assistant_controller_loader.mjs", import.meta.url)

const { renderMarkdownFragment } = await import("../../app/javascript/lib/assistant_markdown.js")
const {
  decorateCodeBlocks,
  normalizeCodeLanguage,
} = await import("../../app/javascript/lib/assistant_code_blocks.js")

function renderMarkdown(body) {
  const root = document.createElement("div")
  root.append(renderMarkdownFragment(document, body))
  return root
}

test("long fenced code starts compact and copies the complete source", () => {
  const source = Array.from(
    { length: 13 },
    (_, i) => i === 0 ? 'puts "<tag>"' : `puts ${i}`,
  ).join("\n")
  const root = renderMarkdown(`\`\`\`ruby\n${source}\n\`\`\``)
  const copied = []
  decorateCodeBlocks(document, root, { onCopy: (text) => copied.push(text) })

  const block = root.querySelector(".assistant-code-block")
  assert.equal(block.dataset.compact, "true")
  assert.equal(block.querySelector('[data-code-action="compact"]').textContent, "Expand")
  block.querySelector('[data-code-action="copy"]').click()
  assert.equal(copied[0], block.querySelector("code").textContent)
  assert.match(copied[0], /puts "<tag>"/)
  assert.match(copied[0], /puts 12/)
  block.querySelector('[data-code-action="compact"]').click()
  assert.equal(block.dataset.compact, "false")
  assert.equal(block.querySelector('[data-code-action="compact"]').textContent, "Compact")
  assert.equal(block.querySelector('[data-code-action="compact"]').getAttribute("aria-expanded"), "true")
})

test("short fenced code stays expanded and inline code is untouched", () => {
  const source = Array.from({ length: 12 }, (_, i) => `const x${i} = ${i}`).join("\n")
  const root = renderMarkdown(`Use \`inline\`\n\n\`\`\`js\n${source}\n\`\`\``)
  decorateCodeBlocks(document, root)

  assert.equal(root.querySelector(".assistant-code-block").dataset.compact, "false")
  assert.equal(root.querySelector("p code").closest(".assistant-code-block"), null)

  const indented = renderMarkdown("    const y = 2\n")
  decorateCodeBlocks(document, indented)
  assert.equal(indented.querySelector(".assistant-code-block"), null)
})

test("language labels are closed inert text and decoration is idempotent", () => {
  assert.equal(normalizeCodeLanguage("ruby"), "ruby")
  assert.equal(normalizeCodeLanguage("c++"), "c++")
  assert.equal(normalizeCodeLanguage("a".repeat(24)), "a".repeat(24))
  for (const value of ["", "a".repeat(25), "ruby html", '"><img src=x onerror=alert(1)>']) {
    assert.equal(normalizeCodeLanguage(value), "Code")
  }

  const root = renderMarkdown('```"><img src=x onerror=alert(1)>\nalert(1)\n```')
  const first = decorateCodeBlocks(document, root)
  const second = decorateCodeBlocks(document, root)
  const toolbar = root.querySelector(".assistant-code-toolbar")

  assert.equal(first.length, 1)
  assert.equal(second.length, 1)
  assert.equal(root.querySelectorAll(".assistant-code-toolbar").length, 1)
  assert.equal(toolbar.querySelector(".assistant-code-language").textContent, "Code")
  assert.equal(toolbar.querySelector("img"), null)
  assert.equal(root.querySelector("pre > code").hasAttribute("title"), false)
})
