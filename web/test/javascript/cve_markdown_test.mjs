import test from "node:test"
import assert from "node:assert/strict"
import { JSDOM } from "jsdom"

const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  url: "https://hunter.test/",
})
globalThis.window = dom.window
globalThis.document = dom.window.document

const {
  renderCveMarkdownFragment,
  safeCveDisplayText,
} = await import("../../app/javascript/lib/cve_markdown.js")

function render(body, options = {}) {
  const host = document.createElement("div")
  host.append(renderCveMarkdownFragment(document, body, options))
  return host
}

test("CVE Markdown keeps useful advisory structure", () => {
  const host = render([
    "# Impact",
    "**Remote attackers** can use `crafted input`; see [the advisory](https://example.com/advisory).",
    "> Upgrade immediately.",
    "- affected\n- fixed",
    "| Package | Version |\n| - | - |\n| foo | 1.2.3 |",
    "```bash\nnpm update foo\n```",
  ].join("\n\n"))

  assert.equal(host.querySelector("h1")?.textContent, "Impact")
  assert.equal(host.querySelector("strong")?.textContent, "Remote attackers")
  assert.equal(host.querySelector("code")?.textContent, "crafted input")
  assert.equal(host.querySelector("a")?.getAttribute("href"), "https://example.com/advisory")
  assert.equal(host.querySelector("blockquote")?.textContent.trim(), "Upgrade immediately.")
  assert.deepEqual([...host.querySelectorAll("li")].map((item) => item.textContent), ["affected", "fixed"])
  assert.equal(host.querySelector("table td")?.textContent, "foo")
  assert.match(host.querySelector("pre code")?.textContent, /npm update foo/)
})

test("raw advisory HTML remains visible text and cannot create active nodes", () => {
  const attack = [
    '<img src=x onerror="alert(1)">',
    "<script>alert(2)</script>",
    '<svg><a xlink:href="javascript:alert(3)">x</a></svg>',
    '<math><mi xlink:href="data:text/html,attack">x</mi></math>',
    '<form><input autofocus onfocus="alert(4)"></form>',
    '<iframe srcdoc="<script>alert(5)</script>"></iframe>',
    "<style>body{display:none}</style>",
    '<custom-element data-secret="x">custom</custom-element>',
  ].join("\n\n")
  const host = render(attack)

  assert.equal(
    host.querySelector("img,script,svg,math,form,input,iframe,style,custom-element"),
    null,
  )
  assert.equal(host.querySelector("[onerror],[onfocus],[srcdoc],[style],[class],[id]"), null)
  assert.match(host.textContent, /<img src=x onerror="alert\(1\)">/)
  assert.match(host.textContent, /<script>alert\(2\)<\/script>/)
  assert.match(host.textContent, /<custom-element data-secret="x">/)
})

test("the sanitizer removes dangerous Markdown link protocols and unapproved attributes", () => {
  const host = render([
    '[javascript](javascript:alert(1) "title")',
    "[data](data:text/html;base64,PHNjcmlwdD4=)",
    '[relative](/cves "safe title")',
  ].join("\n\n"))

  assert.equal(host.querySelector('a[href^="javascript:"]'), null)
  assert.equal(host.querySelector('a[href^="data:"]'), null)
  const relative = [...host.querySelectorAll("a")].find((link) => link.textContent === "relative")
  assert.equal(relative?.getAttribute("href"), "/cves")
  assert.equal(relative?.getAttribute("title"), "safe title")
  assert.equal(relative?.attributes.length, 2)
})

test("mutation-XSS and namespace-confusion input stays inert text", () => {
  const payload = '<math><mtext><table><mglyph><style><!--</style><img title="--></mglyph><img src=1 onerror=alert(1)>"'
  const host = render(payload)

  assert.equal(host.querySelector("math,table,mglyph,style,img"), null)
  assert.equal(host.querySelector("[onerror]"), null)
  assert.match(host.textContent, /<math>/)
})

test("control characters are replaced before CVE Markdown parsing", () => {
  assert.equal(safeCveDisplayText("safe\u0000\u001b[31m"), "safe��[31m")
  const host = render("**safe**\u0000\u001b[31m")

  assert.equal(host.textContent.includes("\u0000"), false)
  assert.equal(host.textContent.includes("\u001b"), false)
  assert.match(host.textContent, /safe.*��\[31m/)
})

test("unsupported or failing dependencies fall back to one inert text node", () => {
  const unsupported = render("**bold**<script>x</script>", {
    purifier: { isSupported: false },
  })
  assert.equal(unsupported.childNodes.length, 1)
  assert.equal(unsupported.firstChild.nodeType, dom.window.Node.TEXT_NODE)
  assert.equal(unsupported.textContent, "**bold**<script>x</script>")

  const parserFailure = render("*body*", {
    parser: { parse() { throw new Error("parser failed") } },
  })
  assert.equal(parserFailure.firstChild.nodeType, dom.window.Node.TEXT_NODE)
  assert.equal(parserFailure.textContent, "*body*")

  const purifierFailure = render("*body*", {
    purifier: { isSupported: true, sanitize() { throw new Error("sanitize failed") } },
  })
  assert.equal(purifierFailure.firstChild.nodeType, dom.window.Node.TEXT_NODE)
  assert.equal(purifierFailure.textContent, "*body*")
})

test("unexpected dependency return types also fall back to inert text", () => {
  const asynchronousParser = render("**body**", {
    parser: { parse() { return Promise.resolve("<strong>body</strong>") } },
  })
  assert.equal(asynchronousParser.childNodes.length, 1)
  assert.equal(asynchronousParser.firstChild.nodeType, dom.window.Node.TEXT_NODE)
  assert.equal(asynchronousParser.textContent, "**body**")

  const stringSanitizer = render("**body**", {
    purifier: { isSupported: true, sanitize() { return "<strong>body</strong>" } },
  })
  assert.equal(stringSanitizer.childNodes.length, 1)
  assert.equal(stringSanitizer.firstChild.nodeType, dom.window.Node.TEXT_NODE)
  assert.equal(stringSanitizer.textContent, "**body**")

  const elementSanitizer = render("**body**", {
    purifier: { isSupported: true, sanitize() { return document.createElement("strong") } },
  })
  assert.equal(elementSanitizer.childNodes.length, 1)
  assert.equal(elementSanitizer.firstChild.nodeType, dom.window.Node.TEXT_NODE)
  assert.equal(elementSanitizer.textContent, "**body**")
})
