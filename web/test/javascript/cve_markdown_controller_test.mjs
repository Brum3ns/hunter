import test from "node:test"
import assert from "node:assert/strict"
import { register } from "node:module"
import { JSDOM } from "jsdom"

const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  url: "https://hunter.test/",
})
globalThis.window = dom.window
globalThis.document = dom.window.document
globalThis.Element = dom.window.Element
globalThis.HTMLElement = dom.window.HTMLElement
globalThis.Node = dom.window.Node
globalThis.MutationObserver = dom.window.MutationObserver
globalThis.CustomEvent = dom.window.CustomEvent
register("./support/cve_markdown_loader.mjs", import.meta.url)

const { Application } = await import("@hotwired/stimulus")
const CveMarkdownController = (
  await import("../../app/javascript/controllers/cve_markdown_controller.js")
).default

function tick() {
  return new Promise((resolve) => setTimeout(resolve, 0))
}

test("the CVE Markdown controller replaces escaped source with sanitized structure", async () => {
  const host = document.createElement("div")
  host.dataset.controller = "cve-markdown"
  host.className = "cve-markdown whitespace-pre-wrap"
  host.textContent = [
    "## Exploit details",
    "A **crafted request** triggers the issue.",
    '[safe advisory](https://example.com/advisory) [unsafe](javascript:alert(1))',
    '<img src=x onerror="alert(2)">',
  ].join("\n\n")
  document.body.append(host)

  const application = Application.start(document.documentElement)
  application.register("cve-markdown", CveMarkdownController)
  await tick()

  assert.equal(host.querySelector("h2")?.textContent, "Exploit details")
  assert.equal(host.querySelector("strong")?.textContent, "crafted request")
  assert.equal(host.querySelector('a[href="https://example.com/advisory"]')?.textContent, "safe advisory")
  assert.equal(host.querySelector('a[href^="javascript:"]'), null)
  assert.equal(host.querySelector("img,[onerror]"), null)
  assert.match(host.textContent, /<img src=x onerror="alert\(2\)">/)
  assert.equal(host.classList.contains("whitespace-pre-wrap"), false)

  const controller = application.getControllerForElementAndIdentifier(host, "cve-markdown")
  controller.connect()
  assert.equal(host.querySelector("h2")?.textContent, "Exploit details")

  application.stop()
})
