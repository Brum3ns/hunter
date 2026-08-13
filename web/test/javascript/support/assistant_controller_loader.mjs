const ROOT = new URL("../../../", import.meta.url)
const MODULES = new Map([
  ["lib/assistant_api", new URL("app/javascript/lib/assistant_api.js", ROOT).href],
  ["lib/assistant_font_scale", new URL("app/javascript/lib/assistant_font_scale.js", ROOT).href],
  ["lib/assistant_history", new URL("app/javascript/lib/assistant_history.js", ROOT).href],
  ["lib/assistant_panel_size", new URL("app/javascript/lib/assistant_panel_size.js", ROOT).href],
  ["lib/assistant_ui", new URL("app/javascript/lib/assistant_ui.js", ROOT).href],
])

export async function resolve(specifier, context, nextResolve) {
  const url = MODULES.get(specifier)
  if (url) return { url, shortCircuit: true }
  return nextResolve(specifier, context)
}
