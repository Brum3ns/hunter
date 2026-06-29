# Hunter side-navigation shell — design

**Date:** 2026-06-29
**Status:** Approved (pending spec review)

## Goal

Replace Hunter's current top-header dashboard layout with a persistent left **side navigation** that defines the app shell for all pages. The sidebar folds (icons only) and unfolds (icons + labels) via a click toggle, persists its state, works well on mobile, and supports both light and dark mode.

## Requirements

- Left side nav as the global app shell.
- **Fold/unfold via a click toggle** (a neatly placed fold/unfold icon). Folded = icons only; unfolded = icons + labels.
- **Persisted** fold state — survives hard reloads and navigation (cookie, server-side first paint, no flicker).
- Two nav groups, top to bottom:
  1. **Account, Settings, Notice** (Notice = notifications, bell icon)
  2. divider
  3. **Dashboard, Bugs, Stats** (main)
- Brand/logo + fold toggle at the very top.
- **Mobile-responsive** — phones are first-class clients.
- **Light/dark mode** — manual toggle defaulting to system preference, persisted.
- Active nav item is visually highlighted.
- Inline Heroicons (outline), no icon-library dependency.

## Approach (and rejected alternatives)

Render the sidebar as a shared layout partial driven by a Stimulus controller, with both fold state and theme read **server-side from cookies** so the correct layout/theme paints on first load.

- **Rejected: pure Stimulus + localStorage** — causes a fold/theme flicker on hard refresh because JS runs after first paint.
- **Rejected: CSS-only checkbox hack** — can't cleanly persist across page loads.
- **Rejected for theme: system-preference only** — user wants a manual override.

## Components

### 1. App shell / layout
`application.html.erb` becomes a two-column flex layout: a fixed-width left `<aside>` + a scrollable `<main>`. A `_sidebar.html.erb` partial holds the nav markup. Sidebar width `w-60` unfolded / `w-16` folded with `transition-[width]`.

### 2. Sidebar structure (top → bottom)
```
┌─ aside ──────────────┐
│ [hunter]   [⟨ toggle]│  brand + fold/unfold icon
├──────────────────────┤
│ ⊙ Account            │  group 1
│ ⚙ Settings           │
│ 🔔 Notice            │
├──────────────────────┤  divider
│ ▦ Dashboard          │  group 2 (main)
│ 🐛 Bugs              │
│ 📊 Stats             │
└──────────────────────┘
```
- Each item = link + inline Heroicon (24px) + label hidden when folded.
- Folded: centered icons, native `title` tooltips. Unfolded: icon + left-aligned label.
- Active state: `bg-zinc-800 text-indigo-400` (dark) / light equivalent, with a subtle left indigo bar. Inactive: muted with hover.
- Brand collapses to mark/initial when folded; toggle chevron flips with state.
- Icons: Dashboard = home/grid, Bugs = bug, Stats = chart-bar, Account = user-circle, Settings = cog, Notice = bell, toggle = chevron/sidebar. Rendered via a small `icon` helper.

### 3. Fold toggle + persistence (JS bootstrap)
The scaffold has Hotwire gems in the Gemfile but the JS bootstrapping was stripped. Recreate:
- `config/importmap.rb`, `app/javascript/application.js`, `app/javascript/controllers/index.js` + `application.js` (Stimulus).
- `<%= javascript_importmap_tags %>` in the layout head.
- `sidebar_controller.js`: on toggle, flip `folded` state (width class, label visibility, chevron) and write a `sidebar_folded` cookie (1-year, `path=/`).
- Layout reads `cookies[:sidebar_folded]` to render the correct width on first paint. Turbo keeps state stable during navigation.

### 4. Responsive / mobile behavior
- **Desktop (`md`+):** sidebar in layout flow; fold/unfold as above.
- **Mobile (`< md`):** sidebar becomes an **off-canvas drawer** — hidden by default, slid in over a dimmed backdrop via a hamburger in a slim top bar. Tapping a link or the backdrop closes it. Drawer always shows icon+label (no folding on phones); the fold cookie governs desktop only.
- Same Stimulus controller handles `toggle` (desktop fold) and `open`/`close` (mobile drawer), keyed to Tailwind breakpoints. Touch targets `min-h-11`.

### 5. Light / dark mode
- Tailwind **class-based dark mode** (`dark` class on `<html>`).
- Convert existing hardcoded-dark views (layout, dashboard, sign-in) to light-default + `dark:` variants. Paired tokens, e.g. `bg-white dark:bg-zinc-900`, `text-zinc-700 dark:text-zinc-300`, `border-zinc-200 dark:border-zinc-800`. Indigo accent in both.
- **Manual toggle defaulting to system preference**, persisted in a `theme` cookie. Switch placed near Account/Settings.
- **No flash of wrong theme:** a tiny inline `<head>` script reads the `theme` cookie, falling back to `matchMedia('prefers-color-scheme')`, and sets the `dark` class before first paint.

### 6. Routes, controllers & placeholder pages
- Add routes + controllers for `bugs`, `stats`, `account`, `settings`, `notifications` (Notice); `dashboard` exists.
- Each placeholder action renders a minimal "coming soon" view in the shared layout so active-state highlighting is real and the whole shell is clickable.

## Testing
- TDD: controller tests asserting each route renders 200 and the layout includes the sidebar with the correct active item.
- Fold/drawer/theme toggles are JS interactions — verified manually in the browser. Noted limitation: cannot automate without a JS-capable system-test driver, which the scaffold doesn't currently have.

## Out of scope
- Real Bugs/Stats/Notifications/Account/Settings features (placeholders only).
- MongoDB-backed vulnerability API (separate, deferred pass).
