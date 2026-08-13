import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { JSDOM } from "jsdom"

const stylesheet = readFileSync(
  new URL("../../app/assets/tailwind/application.css", import.meta.url),
  "utf8",
).replace('@import "tailwindcss";', "")
const template = readFileSync(
  new URL("../../app/views/layouts/_assistant.html.erb", import.meta.url),
  "utf8",
)

function mediaMatches(condition, viewportWidth) {
  const bounds = [...condition.matchAll(/\((min|max)-width:\s*(\d+)px\)/g)]
  if (bounds.length === 0) return false

  return bounds.every(([, kind, value]) => (
    kind === "min" ? viewportWidth >= Number(value) : viewportWidth <= Number(value)
  ))
}

function cascadedStyles(element, rules, viewportWidth, result = new Map()) {
  for (const rule of rules) {
    let matches = false
    if (rule.type === 1) {
      try {
        matches = element.matches(rule.selectorText)
      } catch {
        matches = false
      }
    }

    if (matches) {
      for (let index = 0; index < rule.style.length; index += 1) {
        const property = rule.style.item(index)
        result.set(property, rule.style.getPropertyValue(property))
      }
    } else if (rule.type === 4 && mediaMatches(rule.conditionText, viewportWidth)) {
      cascadedStyles(element, rule.cssRules, viewportWidth, result)
    }
  }

  return result
}

test("mobile expanded history overlays a full-width chat while collapsed history reserves its rail", () => {
  const dom = new JSDOM(`<style>${stylesheet}</style><body>${template}</body>`)
  const rules = dom.window.document.styleSheets[0].cssRules
  const workspace = dom.window.document.querySelector(".assistant-workspace-grid")
  const sidebar = workspace.querySelector(".assistant-history-sidebar")
  const chat = workspace.querySelector(".assistant-chat-column")

  workspace.dataset.historyCollapsed = "false"
  assert.equal(cascadedStyles(workspace, rules, 375).get("grid-template-columns"), "minmax(0, 1fr)")
  assert.equal(cascadedStyles(chat, rules, 375).get("grid-column"), "1")
  assert.equal(cascadedStyles(sidebar, rules, 375).get("position"), "absolute")

  workspace.dataset.historyCollapsed = "true"
  assert.equal(cascadedStyles(workspace, rules, 375).get("grid-template-columns"), "3.25rem minmax(0, 1fr)")
  assert.equal(cascadedStyles(chat, rules, 375).get("grid-column"), "2")
})
