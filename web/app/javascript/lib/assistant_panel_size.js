export const PANEL_SIZE_STORAGE_KEY = "hunter:assistant-panel-size:v1"
export const DEFAULT_PANEL_SIZE = Object.freeze({ width: 680, height: 780 })
export const MIN_PANEL_SIZE = Object.freeze({ width: 480, height: 520 })
export const DESKTOP_BREAKPOINT = 640

const VIEWPORT_GUTTER = 32
const SIZE_KEYS = "height,width"

export function desktopPanel(viewport) {
  return finiteNumber(viewport?.width, 0) >= DESKTOP_BREAKPOINT
}

export function clampPanelSize(size, viewport) {
  const viewportWidth = finiteNumber(viewport?.width, DEFAULT_PANEL_SIZE.width + VIEWPORT_GUTTER)
  const viewportHeight = finiteNumber(viewport?.height, DEFAULT_PANEL_SIZE.height + VIEWPORT_GUTTER)
  const maxWidth = Math.max(0, viewportWidth - VIEWPORT_GUTTER)
  const maxHeight = Math.max(0, viewportHeight - VIEWPORT_GUTTER)
  const minWidth = Math.min(MIN_PANEL_SIZE.width, maxWidth)
  const minHeight = Math.min(MIN_PANEL_SIZE.height, maxHeight)
  const width = finiteNumber(size?.width, DEFAULT_PANEL_SIZE.width)
  const height = finiteNumber(size?.height, DEFAULT_PANEL_SIZE.height)

  return {
    width: clamp(width, minWidth, maxWidth),
    height: clamp(height, minHeight, maxHeight),
  }
}

export function resizeFromPointer(startSize, startPoint, currentPoint, viewport) {
  return clampPanelSize({
    width: startSize.width + startPoint.x - currentPoint.x,
    height: startSize.height + startPoint.y - currentPoint.y,
  }, viewport)
}

export function resizeFromKeyboard(size, key, step, viewport) {
  const delta = finiteNumber(step, 0)
  const next = { width: size.width, height: size.height }

  switch (key) {
  case "ArrowLeft": next.width += delta; break
  case "ArrowRight": next.width -= delta; break
  case "ArrowUp": next.height += delta; break
  case "ArrowDown": next.height -= delta; break
  default: return null
  }

  return clampPanelSize(next, viewport)
}

export function loadPanelSize(storage, viewport) {
  const fallback = () => clampPanelSize(DEFAULT_PANEL_SIZE, viewport)

  try {
    const parsed = JSON.parse(storage.getItem(PANEL_SIZE_STORAGE_KEY))
    if (!closedPanelSize(parsed)) return fallback()
    return clampPanelSize(parsed, viewport)
  } catch {
    return fallback()
  }
}

export function savePanelSize(storage, size) {
  if (!closedPanelSize(size)) return false

  try {
    storage.setItem(PANEL_SIZE_STORAGE_KEY, JSON.stringify({
      width: size.width,
      height: size.height,
    }))
    return true
  } catch {
    return false
  }
}

function closedPanelSize(value) {
  return value !== null &&
    typeof value === "object" &&
    !Array.isArray(value) &&
    Object.keys(value).sort().join(",") === SIZE_KEYS &&
    Number.isFinite(value.width) &&
    Number.isFinite(value.height)
}

function finiteNumber(value, fallback) {
  return Number.isFinite(value) ? value : fallback
}

function clamp(value, minimum, maximum) {
  return Math.min(Math.max(value, minimum), maximum)
}
