const STORAGE_KEY = "hunter:assistant-history-rail:v1"

export function loadHistoryRailCollapsed(storage) {
  try {
    const value = JSON.parse(storage?.getItem(STORAGE_KEY))
    if (!value || Object.keys(value).sort().join() !== "collapsed") return false
    return typeof value.collapsed === "boolean" ? value.collapsed : false
  } catch { return false }
}

export function saveHistoryRailCollapsed(storage, collapsed) {
  try { storage?.setItem(STORAGE_KEY, JSON.stringify({ collapsed: collapsed === true })) } catch {}
}
