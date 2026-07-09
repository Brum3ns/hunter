import { Controller } from "@hotwired/stimulus"

// Exports the scope asset list of a program in three formats:
//   json — [{ "asset": "<asset>" }, …]  (any asset shape — hostnames,
//          CIDRs, App Store IDs, source repos, …)
//   text — one asset per line
//   burp — Burp-style regexes one per line; CIDRs keep their /prefix,
//          everything else is reduced to a host-only regex.
// The asset list is passed via data-asset-export-assets-value as a JSON
// array of strings; the program slug seeds the download filename.
export default class extends Controller {
  static values = {
    assets: Array,
    slug:   { type: String, default: "scope" }
  }

  json(event) {
    event?.preventDefault?.()
    this._download(`${this._baseName()}.json`, this._jsonBody(), "application/json")
  }

  text(event) {
    event?.preventDefault?.()
    this._download(`${this._baseName()}.txt`, this._textBody(), "text/plain")
  }

  burp(event) {
    event?.preventDefault?.()
    this._download(`${this._baseName()}-burp.txt`, this._burpBody(), "text/plain")
  }

  copyJson(event) {
    event?.preventDefault?.()
    this._copy(event?.currentTarget, this._jsonBody())
  }

  copyText(event) {
    event?.preventDefault?.()
    this._copy(event?.currentTarget, this._textBody())
  }

  copyBurp(event) {
    event?.preventDefault?.()
    this._copy(event?.currentTarget, this._burpBody())
  }

  _jsonBody() {
    return JSON.stringify(this.assetsValue.map((a) => ({ asset: a })), null, 2)
  }

  _textBody() {
    return this.assetsValue.join("\n") + "\n"
  }

  _burpBody() {
    return this.assetsValue.map((a) => this._toBurp(a)).filter(Boolean).join("\n") + "\n"
  }

  // Convert an asset string into a Burp-compatible regex.
  //
  //   CIDR ranges (IPv4 or IPv6) keep the slash + prefix — Burp's host
  //   matcher chokes on a bare IP when the original scope was a range,
  //   so `127.0.0.1/24` must stay as `127\.0\.0\.1/24`.
  //
  //   URLs and hostnames get their scheme, path, query, and port stripped
  //   so only the host survives. The host is then regex-escaped and the
  //   wildcard glob `*` is upgraded to `.*`.
  //
  // Empty results (e.g. App Store IDs that reduce to nothing) are
  // filtered out by the caller.
  _toBurp(raw) {
    const s = (raw || "").trim()
    if (!s) return ""

    if (this._isCidr(s)) {
      return s.replace(/[.+?^${}()|[\]\\]/g, "\\$&")
    }

    let host = s.replace(/^[a-z][a-z0-9+.\-]*:\/\//i, "")
    host = host.split("/")[0]
    host = host.split("?")[0]
    host = host.split("#")[0]
    host = host.replace(/:\d+$/, "")
    if (!host) return ""
    const escaped = host.replace(/[.+?^${}()|[\]\\]/g, "\\$&")
    return escaped.replace(/\*/g, ".*")
  }

  // Loose CIDR detector — strict enough to reject "example.com/v1" but
  // accepting both IPv4 (10.0.0.0/24) and IPv6 (fe80::/10) shapes.
  _isCidr(s) {
    if (/^\d{1,3}(?:\.\d{1,3}){3}\/\d{1,2}$/.test(s)) return true
    if (/^[0-9a-f:]+\/\d{1,3}$/i.test(s) && s.includes(":")) return true
    return false
  }

  _baseName() {
    const slug = (this.slugValue || "scope").replace(/[^a-z0-9._-]+/gi, "-")
    return `${slug}-scope`
  }

  // Mirror clipboard_controller's flash convention so CSS can react to a
  // successful copy by checking data-copied="true" on the button.
  _copy(button, text) {
    const done = () => {
      if (!button) return
      button.dataset.copied = "true"
      clearTimeout(button._copyTimer)
      button._copyTimer = setTimeout(() => { delete button.dataset.copied }, 1100)
    }
    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(text).then(done, () => this._copyFallback(text, done))
    } else {
      this._copyFallback(text, done)
    }
  }

  _copyFallback(text, done) {
    const ta = document.createElement("textarea")
    ta.value = text
    ta.setAttribute("readonly", "")
    ta.style.position = "fixed"
    ta.style.opacity = "0"
    document.body.appendChild(ta)
    ta.select()
    try { document.execCommand("copy"); done() } finally { ta.remove() }
  }

  _download(filename, body, mime) {
    const blob = new Blob([body], { type: `${mime};charset=utf-8` })
    const url = URL.createObjectURL(blob)
    const a = document.createElement("a")
    a.href = url
    a.download = filename
    document.body.appendChild(a)
    a.click()
    a.remove()
    setTimeout(() => URL.revokeObjectURL(url), 1000)
  }
}
