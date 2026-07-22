// One-time generator: extracts {slug,title,hex,path} for every Simple Icon into
// icons.json. Run with the pinned simple-icons version installed (see VERSION).
// Usage (from web/vendor/simple-icons/):
//   npm i simple-icons@16.26.0 --no-save --prefix /tmp/si && node generate.mjs /tmp/si
import { writeFileSync } from "node:fs";

const prefix = process.argv[2] || "/tmp/si";
const si = await import(prefix + "/node_modules/simple-icons/index.mjs");

const out = {};
for (const key of Object.keys(si)) {
  const icon = si[key];
  if (!icon || !icon.slug || !icon.path || !icon.hex) continue;
  out[icon.slug] = { title: icon.title, hex: icon.hex, path: icon.path };
}
writeFileSync(
  new URL("./icons.json", import.meta.url),
  JSON.stringify(out) + "\n"
);
console.log(`wrote ${Object.keys(out).length} icons`);
