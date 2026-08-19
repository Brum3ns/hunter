const CVE_MARKDOWN = new URL(
  "../../../app/javascript/lib/cve_markdown.js",
  import.meta.url,
).href

export async function resolve(specifier, context, nextResolve) {
  if (specifier === "lib/cve_markdown") {
    return { url: CVE_MARKDOWN, shortCircuit: true }
  }

  return nextResolve(specifier, context)
}
