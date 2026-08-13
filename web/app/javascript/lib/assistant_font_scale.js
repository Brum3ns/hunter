export const FONT_SCALE_STORAGE_KEY = "hunter:assistant-font-scale:v1"
export const FONT_SCALES = Object.freeze([0.875, 1, 1.125, 1.25])
export const DEFAULT_FONT_SCALE_INDEX = 1

function validIndex(index) {
  return Number.isInteger(index) && index >= 0 && index < FONT_SCALES.length
}

export function changeFontScale(index, delta) {
  const current = validIndex(index) ? index : DEFAULT_FONT_SCALE_INDEX
  const next = Math.min(Math.max(current + delta, 0), FONT_SCALES.length - 1)
  return { index: next, value: FONT_SCALES[next] }
}

export function loadFontScaleIndex(storage) {
  try {
    const raw = storage?.getItem(FONT_SCALE_STORAGE_KEY)
    if (!raw) return DEFAULT_FONT_SCALE_INDEX
    const parsed = JSON.parse(raw)
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      return DEFAULT_FONT_SCALE_INDEX
    }
    if (Object.keys(parsed).sort().join(",") !== "index" || !validIndex(parsed.index)) {
      return DEFAULT_FONT_SCALE_INDEX
    }
    return parsed.index
  } catch {
    return DEFAULT_FONT_SCALE_INDEX
  }
}

export function saveFontScaleIndex(storage, index) {
  if (!validIndex(index)) return false
  try {
    storage?.setItem(FONT_SCALE_STORAGE_KEY, JSON.stringify({ index }))
    return Boolean(storage)
  } catch {
    return false
  }
}
