# Hunter Side-Navigation Shell Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Hunter's top-header dashboard with a persistent, foldable left side-navigation shell that is mobile-responsive and supports light/dark mode.

**Architecture:** A shared `_sidebar` layout partial renders two icon+label nav groups. Fold state and theme are persisted in cookies; fold width is rendered server-side on first paint, theme is applied by a no-flash inline `<head>` script (cookie → `prefers-color-scheme` fallback). A single Stimulus controller handles desktop fold, mobile off-canvas drawer, and the theme toggle.

**Tech Stack:** Ruby 3.3.6, Rails 8, Tailwind CSS v4 (`tailwindcss-rails`, `@import "tailwindcss"`), importmap-rails + Stimulus + Turbo (Hotwire), Propshaft, inline Heroicons (outline), Minitest.

## Global Constraints

- Rails app lives in `web/`; all paths below are relative to `web/` unless noted. The git repo root is the parent of `web/`.
- Ruby module namespace is `Hunter`; databases are `hunter_*`.
- Auth: Rails 8 built-in, username-only. Authenticated user is `Current.user`; controllers inherit `require_authentication` from `Authentication`. Unauthenticated requests redirect to `new_session_path`.
- Dark theme baseline palette already in use: zinc scale + indigo-600 accent. Light mode must pair every dark surface token (e.g. `bg-white dark:bg-zinc-900`).
- Cookie names (exact): `sidebar_folded` (values `"1"` folded / absent or `"0"` unfolded), `theme` (values `"dark"` / `"light"`).
- Tests run with `bin/rails test` from `web/`. A Postgres `hunter_test` database must be reachable (the app's Postgres runs via docker-compose); do not start servers as part of a step — assume the DB is available when running tests.
- Commit author for all commits: `Claude <noreply@anthropic.com>` via `git -c user.name='Claude' -c user.email='noreply@anthropic.com' commit ...`. Commit messages are a single sentence, no body.

---

## File Structure

- `config/routes.rb` — add 5 placeholder routes (modify).
- `app/controllers/{bugs,stats,account,settings,notifications}_controller.rb` — placeholder controllers (create).
- `app/views/{bugs,stats,account,settings,notifications}/{index,show}.html.erb` — placeholder views (create).
- `app/helpers/icon_helper.rb` — inline Heroicon renderer (create).
- `app/helpers/navigation_helper.rb` — active-nav predicate (create).
- `app/assets/tailwind/application.css` — enable class-based dark variant (modify).
- `config/importmap.rb`, `app/javascript/application.js`, `app/javascript/controllers/{application,index}.js` — Hotwire bootstrap (create).
- `app/javascript/controllers/sidebar_controller.js` — fold / drawer / theme controller (create).
- `app/views/layouts/_sidebar.html.erb` — sidebar partial (create).
- `app/views/layouts/application.html.erb` — two-column shell, head theme script, importmap tags (modify).
- `app/views/dashboard/index.html.erb`, `app/views/sessions/new.html.erb` — light/dark conversion (modify).
- `test/controllers/navigation_placeholders_test.rb`, `test/helpers/icon_helper_test.rb`, `test/helpers/navigation_helper_test.rb`, `test/integration/sidebar_shell_test.rb` — tests (create).

---

## Task 1: Placeholder routes, controllers & views

**Files:**
- Modify: `config/routes.rb`
- Create: `app/controllers/bugs_controller.rb`, `app/controllers/stats_controller.rb`, `app/controllers/account_controller.rb`, `app/controllers/settings_controller.rb`, `app/controllers/notifications_controller.rb`
- Create: `app/views/bugs/index.html.erb`, `app/views/stats/index.html.erb`, `app/views/account/show.html.erb`, `app/views/settings/show.html.erb`, `app/views/notifications/index.html.erb`
- Test: `test/controllers/navigation_placeholders_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: path helpers `bugs_path`, `stats_path`, `account_path`, `settings_path`, `notifications_path`. Controller names (`controller.controller_name`): `"bugs"`, `"stats"`, `"account"`, `"settings"`, `"notifications"`, plus the existing `"dashboard"`. Task 5 links to these and highlights by controller name.

- [ ] **Step 1: Write the failing test**

Create `test/controllers/navigation_placeholders_test.rb`:

```ruby
require "test_helper"

class NavigationPlaceholdersTest < ActionDispatch::IntegrationTest
  PATHS = %w[/bugs /stats /account /settings /notifications].freeze

  test "each placeholder renders for an authenticated user" do
    sign_in_as(User.take)
    PATHS.each do |path|
      get path
      assert_response :success, "expected 200 for #{path}"
    end
  end

  test "each placeholder redirects an unauthenticated visitor to sign in" do
    PATHS.each do |path|
      get path
      assert_redirected_to new_session_path, "expected redirect for #{path}"
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/controllers/navigation_placeholders_test.rb`
Expected: FAIL — routing error / no route matches `/bugs`.

- [ ] **Step 3: Add the routes**

In `config/routes.rb`, add directly under the existing `root "dashboard#index"` line:

```ruby
  get "bugs", to: "bugs#index"
  get "stats", to: "stats#index"
  get "account", to: "account#show"
  get "settings", to: "settings#show"
  get "notifications", to: "notifications#index"
```

- [ ] **Step 4: Create the controllers**

`app/controllers/bugs_controller.rb`:

```ruby
class BugsController < ApplicationController
  def index
  end
end
```

`app/controllers/stats_controller.rb`:

```ruby
class StatsController < ApplicationController
  def index
  end
end
```

`app/controllers/account_controller.rb`:

```ruby
class AccountController < ApplicationController
  def show
  end
end
```

`app/controllers/settings_controller.rb`:

```ruby
class SettingsController < ApplicationController
  def show
  end
end
```

`app/controllers/notifications_controller.rb`:

```ruby
class NotificationsController < ApplicationController
  def index
  end
end
```

- [ ] **Step 5: Create the placeholder views**

Each view is a minimal "coming soon" panel. Use this exact body, substituting the title per file:

`app/views/bugs/index.html.erb`:

```erb
<% content_for :title, "hunter — Bugs" %>
<h1 class="text-2xl font-semibold text-zinc-900 dark:text-zinc-100">Bugs</h1>
<p class="mt-2 text-zinc-500 dark:text-zinc-400">Bug tracking is coming soon.</p>
```

`app/views/stats/index.html.erb` — same, title `"hunter — Stats"`, heading `Stats`, copy `Statistics are coming soon.`
`app/views/account/show.html.erb` — title `"hunter — Account"`, heading `Account`, copy `Account settings are coming soon.`
`app/views/settings/show.html.erb` — title `"hunter — Settings"`, heading `Settings`, copy `Settings are coming soon.`
`app/views/notifications/index.html.erb` — title `"hunter — Notice"`, heading `Notice`, copy `Notifications are coming soon.`

- [ ] **Step 6: Run test to verify it passes**

Run: `bin/rails test test/controllers/navigation_placeholders_test.rb`
Expected: PASS (2 tests).

- [ ] **Step 7: Commit**

```bash
git -c user.name='Claude' -c user.email='noreply@anthropic.com' \
  commit -am "Add placeholder pages for bugs, stats, account, settings, and notifications"
```
(Run `git add -A` first if any files are untracked.)

---

## Task 2: Heroicon helper

**Files:**
- Create: `app/helpers/icon_helper.rb`
- Test: `test/helpers/icon_helper_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `heroicon(name, classes: "h-6 w-6")` → HTML-safe `<svg>` string. Valid `name` values: `"home"`, `"bug-ant"`, `"chart-bar"`, `"user-circle"`, `"cog"`, `"bell"`, `"chevron-double-left"`, `"bars-3"`, `"x-mark"`, `"sun"`, `"moon"`. Unknown name raises `ArgumentError`. Task 5 and Task 6's partial call this.

- [ ] **Step 1: Write the failing test**

Create `test/helpers/icon_helper_test.rb`:

```ruby
require "test_helper"

class IconHelperTest < ActionView::TestCase
  include IconHelper

  test "renders an svg with the requested classes" do
    html = heroicon("bell", classes: "h-5 w-5 text-indigo-500")
    assert_includes html, "<svg"
    assert_includes html, "h-5 w-5 text-indigo-500"
    assert_includes html, "stroke=\"currentColor\""
    assert html.html_safe?
  end

  test "renders multi-path icons like cog" do
    html = heroicon("cog")
    assert_equal 2, html.scan("<path").length
  end

  test "raises for an unknown icon" do
    assert_raises(ArgumentError) { heroicon("nope") }
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/helpers/icon_helper_test.rb`
Expected: FAIL — `uninitialized constant IconHelper`.

- [ ] **Step 3: Implement the helper**

Create `app/helpers/icon_helper.rb`:

```ruby
module IconHelper
  HEROICON_PATHS = {
    "home" => [
      "M2.25 12l8.954-8.955c.44-.439 1.152-.439 1.591 0L21.75 12M4.5 9.75v10.125c0 .621.504 1.125 1.125 1.125H9.75v-4.875c0-.621.504-1.125 1.125-1.125h2.25c.621 0 1.125.504 1.125 1.125V21h4.125c.621 0 1.125-.504 1.125-1.125V9.75M8.25 21h8.25"
    ],
    "bug-ant" => [
      "M12 12.75c1.148 0 2.278.08 3.383.237 1.037.146 1.866.966 1.866 2.013 0 3.728-2.35 6.75-5.25 6.75S6.75 18.728 6.75 15c0-1.046.83-1.867 1.866-2.013A24.204 24.204 0 0112 12.75zm0 0c2.883 0 5.647.508 8.207 1.44a23.91 23.91 0 01-1.152 6.06M12 12.75c-2.883 0-5.647.508-8.208 1.44.125 2.104.52 4.136 1.153 6.06M12 12.75a2.25 2.25 0 002.248-2.354M12 12.75a2.25 2.25 0 01-2.248-2.354M12 8.25c.995 0 1.971-.08 2.922-.236.403-.066.74-.358.795-.762a3.778 3.778 0 00-.399-2.25M12 8.25c-.995 0-1.97-.08-2.922-.236-.402-.066-.74-.358-.795-.762a3.734 3.734 0 01.4-2.253M12 8.25a2.25 2.25 0 00-2.248 2.146M12 8.25a2.25 2.25 0 012.248 2.146M8.683 5a6.032 6.032 0 01-1.155-1.002c-.43-.51-.604-1.2-.563-1.86a48.7 48.7 0 015.567 0c.04.66-.133 1.35-.563 1.86A6.032 6.032 0 0112 5M8.683 5a6.032 6.032 0 006.634 0M8.683 5a47.792 47.792 0 006.634 0"
    ],
    "chart-bar" => [
      "M3 13.125C3 12.504 3.504 12 4.125 12h2.25c.621 0 1.125.504 1.125 1.125v6.75C7.5 20.496 6.996 21 6.375 21h-2.25A1.125 1.125 0 013 19.875v-6.75zM9.75 8.625c0-.621.504-1.125 1.125-1.125h2.25c.621 0 1.125.504 1.125 1.125v11.25c0 .621-.504 1.125-1.125 1.125h-2.25a1.125 1.125 0 01-1.125-1.125V8.625zM16.5 4.125c0-.621.504-1.125 1.125-1.125h2.25C20.496 3 21 3.504 21 4.125v15.75c0 .621-.504 1.125-1.125 1.125h-2.25a1.125 1.125 0 01-1.125-1.125V4.125z"
    ],
    "user-circle" => [
      "M17.982 18.725A7.488 7.488 0 0012 15.75a7.488 7.488 0 00-5.982 2.975m11.963 0a9 9 0 10-11.963 0m11.963 0A8.966 8.966 0 0112 21a8.966 8.966 0 01-5.982-2.275M15 9.75a3 3 0 11-6 0 3 3 0 016 0z"
    ],
    "cog" => [
      "M9.594 3.94c.09-.542.56-.94 1.11-.94h2.593c.55 0 1.02.398 1.11.94l.213 1.281c.063.374.313.686.645.87.074.04.147.083.22.127.325.196.72.257 1.075.124l1.217-.456a1.125 1.125 0 011.37.49l1.296 2.247a1.125 1.125 0 01-.26 1.431l-1.003.827c-.293.24-.438.613-.43.992a7.723 7.723 0 010 .255c-.008.378.137.75.43.991l1.004.827c.424.35.534.955.26 1.43l-1.298 2.247a1.125 1.125 0 01-1.369.491l-1.217-.456c-.355-.133-.75-.072-1.076.124a6.47 6.47 0 01-.22.128c-.331.183-.581.495-.644.869l-.213 1.281c-.09.543-.56.94-1.11.94h-2.594c-.55 0-1.019-.398-1.11-.94l-.213-1.281c-.062-.374-.312-.686-.644-.87a6.52 6.52 0 01-.22-.127c-.325-.196-.72-.257-1.076-.124l-1.217.456a1.125 1.125 0 01-1.369-.49l-1.297-2.247a1.125 1.125 0 01.26-1.431l1.004-.827c.292-.24.437-.613.43-.992a6.932 6.932 0 010-.255c.007-.378-.138-.75-.43-.991l-1.004-.827a1.125 1.125 0 01-.26-1.43l1.297-2.247a1.125 1.125 0 011.37-.491l1.216.456c.356.133.751.072 1.076-.124.072-.044.146-.087.22-.128.332-.183.582-.495.644-.869l.214-1.281z",
      "M15 12a3 3 0 11-6 0 3 3 0 016 0z"
    ],
    "bell" => [
      "M14.857 17.082a23.848 23.848 0 005.454-1.31A8.967 8.967 0 0118 9.75v-.7V9A6 6 0 006 9v.75a8.967 8.967 0 01-2.312 6.022c1.733.64 3.56 1.085 5.455 1.31m5.714 0a24.255 24.255 0 01-5.714 0m5.714 0a3 3 0 11-5.714 0"
    ],
    "chevron-double-left" => [
      "M18.75 4.5l-7.5 7.5 7.5 7.5m-6-15L5.25 12l7.5 7.5"
    ],
    "bars-3" => [
      "M3.75 6.75h16.5M3.75 12h16.5m-16.5 5.25h16.5"
    ],
    "x-mark" => [
      "M6 18L18 6M6 6l12 12"
    ],
    "sun" => [
      "M12 3v2.25m6.364.386l-1.591 1.591M21 12h-2.25m-.386 6.364l-1.591-1.591M12 18.75V21m-4.773-4.227l-1.591 1.591M5.25 12H3m4.227-4.773L5.636 5.636M15.75 12a3.75 3.75 0 11-7.5 0 3.75 3.75 0 017.5 0z"
    ],
    "moon" => [
      "M21.752 15.002A9.72 9.72 0 0118 15.75c-5.385 0-9.75-4.365-9.75-9.75 0-1.33.266-2.597.748-3.752A9.753 9.753 0 003 11.25C3 16.635 7.365 21 12.75 21a9.753 9.753 0 009.002-5.998z"
    ]
  }.freeze

  def heroicon(name, classes: "h-6 w-6")
    paths = HEROICON_PATHS[name] || raise(ArgumentError, "Unknown heroicon: #{name}")
    inner = paths.map do |d|
      tag.path(d: d, "stroke-linecap": "round", "stroke-linejoin": "round")
    end
    content_tag(:svg,
      safe_join(inner),
      xmlns: "http://www.w3.org/2000/svg",
      fill: "none",
      viewBox: "0 0 24 24",
      "stroke-width": "1.5",
      stroke: "currentColor",
      "aria-hidden": "true",
      class: classes)
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/helpers/icon_helper_test.rb`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git -c user.name='Claude' -c user.email='noreply@anthropic.com' \
  commit -am "Add inline Heroicon view helper"
```

---

## Task 3: Navigation active-state helper

**Files:**
- Create: `app/helpers/navigation_helper.rb`
- Test: `test/helpers/navigation_helper_test.rb`

**Interfaces:**
- Consumes: `controller.controller_name` (from Task 1 controllers + existing dashboard).
- Produces: `nav_active?(*controller_names)` → boolean (true when the current request's controller_name is in the list). Task 5 uses it to pick link classes.

- [ ] **Step 1: Write the failing test**

Create `test/helpers/navigation_helper_test.rb`:

```ruby
require "test_helper"

class NavigationHelperTest < ActionView::TestCase
  include NavigationHelper

  test "true when current controller matches" do
    def controller_name = "bugs"
    assert nav_active?("bugs")
  end

  test "false when current controller does not match" do
    def controller_name = "dashboard"
    assert_not nav_active?("bugs", "stats")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/helpers/navigation_helper_test.rb`
Expected: FAIL — `uninitialized constant NavigationHelper`.

- [ ] **Step 3: Implement the helper**

Create `app/helpers/navigation_helper.rb`:

```ruby
module NavigationHelper
  def nav_active?(*controller_names)
    controller_names.flatten.include?(controller_name)
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/helpers/navigation_helper_test.rb`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git -c user.name='Claude' -c user.email='noreply@anthropic.com' \
  commit -am "Add navigation active-state helper"
```

---

## Task 4: Bootstrap Hotwire JS + enable class-based dark mode

**Files:**
- Create: `config/importmap.rb`, `app/javascript/application.js`, `app/javascript/controllers/application.js`, `app/javascript/controllers/index.js`
- Modify: `app/assets/tailwind/application.css`, `app/views/layouts/application.html.erb`
- Test: `test/integration/sidebar_shell_test.rb` (first assertion only; expanded in Task 5)

**Interfaces:**
- Consumes: nothing.
- Produces: a working importmap that loads `@hotwired/turbo-rails` and `@hotwired/stimulus`, an `application` Stimulus instance registered globally, and a `dark` class variant in Tailwind. Task 5 adds `<aside>` markup and Task 6 adds the `sidebar` controller that this registry auto-loads.

- [ ] **Step 1: Write the failing test**

Create `test/integration/sidebar_shell_test.rb`:

```ruby
require "test_helper"

class SidebarShellTest < ActionDispatch::IntegrationTest
  setup { sign_in_as(User.take) }

  test "layout includes the importmap module script" do
    get root_path
    assert_response :success
    assert_select "script[type=importmap]", count: 1
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/integration/sidebar_shell_test.rb`
Expected: FAIL — no `script[type=importmap]` because the layout has no `javascript_importmap_tags`.

- [ ] **Step 3: Create the importmap pin file**

Create `config/importmap.rb`:

```ruby
pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"
```

- [ ] **Step 4: Create the JS entrypoint and Stimulus wiring**

`app/javascript/application.js`:

```js
import "@hotwired/turbo-rails"
import "controllers"
```

`app/javascript/controllers/application.js`:

```js
import { Application } from "@hotwired/stimulus"

const application = Application.start()
application.debug = false
window.Stimulus = application

export { application }
```

`app/javascript/controllers/index.js`:

```js
import { application } from "controllers/application"
import { eagerLoadControllersFrom } from "@hotwired/stimulus-loading"
eagerLoadControllersFrom("controllers", application)
```

- [ ] **Step 5: Enable class-based dark mode in Tailwind**

Replace the contents of `app/assets/tailwind/application.css` with:

```css
@import "tailwindcss";

@custom-variant dark (&:where(.dark, .dark *));
```

- [ ] **Step 6: Add importmap tags to the layout head**

In `app/views/layouts/application.html.erb`, add immediately after the `stylesheet_link_tag` line (line 22):

```erb
    <%= javascript_importmap_tags %>
```

- [ ] **Step 7: Run test to verify it passes**

Run: `bin/rails test test/integration/sidebar_shell_test.rb`
Expected: PASS (1 test). If the importmap assets fail to resolve, run `bin/rails importmap:install`-equivalent is NOT needed — the pins above plus `importmap-rails` vendored assets are sufficient; ensure `vendor/javascript` has `turbo.min.js`, `stimulus.min.js`, `stimulus-loading.js` (run `bin/importmap pin @hotwired/turbo-rails @hotwired/stimulus @hotwired/stimulus-loading` if missing).

- [ ] **Step 8: Commit**

```bash
git add -A && git -c user.name='Claude' -c user.email='noreply@anthropic.com' \
  commit -m "Bootstrap importmap and Stimulus and enable class-based dark mode"
```

---

## Task 5: Sidebar partial + app-shell layout

**Files:**
- Create: `app/views/layouts/_sidebar.html.erb`
- Modify: `app/views/layouts/application.html.erb`
- Test: `test/integration/sidebar_shell_test.rb` (expand)

**Interfaces:**
- Consumes: `heroicon` (Task 2), `nav_active?` (Task 3), path helpers (Task 1), cookies `sidebar_folded` / `theme`.
- Produces: an `<aside data-controller="sidebar">` with `data-sidebar-target="aside"`, nav links carrying `data-sidebar-target="label"` on their text spans, a fold toggle (`data-action="sidebar#toggle"`), a mobile hamburger (`data-action="sidebar#open"`), a backdrop (`data-action="sidebar#close"` / `data-sidebar-target="backdrop"`), and a theme toggle (`data-action="sidebar#toggleTheme"`). Task 6 implements those actions/targets.

- [ ] **Step 1: Expand the failing test**

Replace `test/integration/sidebar_shell_test.rb` with:

```ruby
require "test_helper"

class SidebarShellTest < ActionDispatch::IntegrationTest
  setup { sign_in_as(User.take) }

  test "layout includes the importmap module script" do
    get root_path
    assert_select "script[type=importmap]", count: 1
  end

  test "renders the sidebar with all nav links" do
    get root_path
    assert_select "aside[data-controller=sidebar]", count: 1
    assert_select "a[href=?]", root_path
    assert_select "a[href=?]", bugs_path
    assert_select "a[href=?]", stats_path
    assert_select "a[href=?]", account_path
    assert_select "a[href=?]", settings_path
    assert_select "a[href=?]", notifications_path
  end

  test "highlights the active section" do
    get bugs_path
    assert_select "a[href=?][aria-current=page]", bugs_path
    assert_select "a[href=?]:not([aria-current])", stats_path
  end

  test "renders folded width when the cookie is set" do
    cookies[:sidebar_folded] = "1"
    get root_path
    assert_select "aside[data-controller=sidebar][class*=?]", "md:w-16"
  end

  test "renders unfolded width by default" do
    get root_path
    assert_select "aside[data-controller=sidebar][class*=?]", "md:w-60"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/integration/sidebar_shell_test.rb`
Expected: FAIL — no `aside[data-controller=sidebar]`.

- [ ] **Step 3: Create the sidebar partial**

Create `app/views/layouts/_sidebar.html.erb`:

```erb
<% folded = cookies[:sidebar_folded] == "1" %>

<%# Mobile top bar with hamburger %>
<div class="flex items-center gap-3 border-b border-zinc-200 bg-white px-4 py-3 md:hidden dark:border-zinc-800 dark:bg-zinc-900">
  <button type="button" data-action="sidebar#open"
          class="inline-flex h-11 w-11 items-center justify-center rounded-md text-zinc-600 hover:bg-zinc-100 dark:text-zinc-300 dark:hover:bg-zinc-800"
          aria-label="Open navigation">
    <%= heroicon "bars-3" %>
  </button>
  <span class="text-lg font-bold tracking-tight text-zinc-900 dark:text-zinc-100">hunter</span>
</div>

<%# Backdrop (mobile only, hidden until drawer opens) %>
<div data-sidebar-target="backdrop" data-action="sidebar#close"
     class="fixed inset-0 z-30 hidden bg-black/50 md:hidden"></div>

<aside data-controller="sidebar"
       data-sidebar-target="aside"
       class="fixed inset-y-0 left-0 z-40 flex w-60 -translate-x-full flex-col border-r border-zinc-200 bg-white transition-[width,transform] duration-200 ease-in-out md:static md:translate-x-0 dark:border-zinc-800 dark:bg-zinc-900 <%= folded ? 'md:w-16' : 'md:w-60' %>">

  <%# Brand + fold toggle %>
  <div class="flex items-center justify-between gap-2 border-b border-zinc-200 px-4 py-4 dark:border-zinc-800">
    <span class="text-lg font-bold tracking-tight text-zinc-900 dark:text-zinc-100 <%= 'md:hidden' if folded %>" data-sidebar-target="label">hunter</span>
    <button type="button" data-action="sidebar#toggle"
            class="hidden h-9 w-9 items-center justify-center rounded-md text-zinc-500 hover:bg-zinc-100 md:inline-flex dark:text-zinc-400 dark:hover:bg-zinc-800"
            aria-label="Toggle sidebar">
      <%= heroicon "chevron-double-left", classes: "h-5 w-5 transition-transform #{'rotate-180' if folded}" %>
    </button>
    <%# Close button (mobile drawer) %>
    <button type="button" data-action="sidebar#close"
            class="inline-flex h-9 w-9 items-center justify-center rounded-md text-zinc-500 hover:bg-zinc-100 md:hidden dark:text-zinc-400 dark:hover:bg-zinc-800"
            aria-label="Close navigation">
      <%= heroicon "x-mark", classes: "h-5 w-5" %>
    </button>
  </div>

  <nav class="flex flex-1 flex-col gap-1 overflow-y-auto px-2 py-4">
    <%# Group 1: account / settings / notice %>
    <%= render "layouts/sidebar_link", path: account_path, controllers: %w[account], icon: "user-circle", label: "Account", folded: folded %>
    <%= render "layouts/sidebar_link", path: settings_path, controllers: %w[settings], icon: "cog", label: "Settings", folded: folded %>
    <%= render "layouts/sidebar_link", path: notifications_path, controllers: %w[notifications], icon: "bell", label: "Notice", folded: folded %>

    <hr class="my-3 border-zinc-200 dark:border-zinc-800">

    <%# Group 2: main %>
    <%= render "layouts/sidebar_link", path: root_path, controllers: %w[dashboard], icon: "home", label: "Dashboard", folded: folded %>
    <%= render "layouts/sidebar_link", path: bugs_path, controllers: %w[bugs], icon: "bug-ant", label: "Bugs", folded: folded %>
    <%= render "layouts/sidebar_link", path: stats_path, controllers: %w[stats], icon: "chart-bar", label: "Stats", folded: folded %>
  </nav>

  <%# Footer: theme toggle + sign out %>
  <div class="flex items-center gap-1 border-t border-zinc-200 px-2 py-3 dark:border-zinc-800">
    <button type="button" data-action="sidebar#toggleTheme"
            class="inline-flex h-11 min-w-11 items-center justify-center gap-2 rounded-md px-2 text-zinc-600 hover:bg-zinc-100 dark:text-zinc-300 dark:hover:bg-zinc-800"
            aria-label="Toggle theme">
      <span class="hidden dark:inline"><%= heroicon "sun", classes: "h-5 w-5" %></span>
      <span class="inline dark:hidden"><%= heroicon "moon", classes: "h-5 w-5" %></span>
    </button>
    <%= button_to session_path, method: :delete,
          class: "inline-flex h-11 min-w-11 flex-1 items-center justify-center gap-2 rounded-md px-2 text-zinc-600 hover:bg-zinc-100 dark:text-zinc-300 dark:hover:bg-zinc-800" do %>
      <%= heroicon "user-circle", classes: "h-5 w-5" %>
      <span class="<%= 'md:hidden' if folded %>" data-sidebar-target="label">Sign out</span>
    <% end %>
  </div>
</aside>
```

- [ ] **Step 4: Create the shared link partial**

Create `app/views/layouts/_sidebar_link.html.erb`:

```erb
<%
  active = nav_active?(controllers)
  base = "group flex min-h-11 items-center gap-3 rounded-md px-3 text-sm font-medium transition-colors"
  state = active ? "bg-zinc-100 text-indigo-600 dark:bg-zinc-800 dark:text-indigo-400" : "text-zinc-600 hover:bg-zinc-100 dark:text-zinc-400 dark:hover:bg-zinc-800/60"
%>
<%= link_to path, title: label, "aria-current": (active ? "page" : nil), class: "#{base} #{state}" do %>
  <span class="shrink-0 <%= 'text-indigo-600 dark:text-indigo-400' if active %>"><%= heroicon icon, classes: "h-6 w-6" %></span>
  <span class="<%= 'md:hidden' if folded %>" data-sidebar-target="label"><%= label %></span>
<% end %>
```

- [ ] **Step 5: Rewrite the layout body as a two-column shell**

In `app/views/layouts/application.html.erb`, replace the entire `<body>...</body>` (lines 25-27) with:

```erb
  <body class="min-h-screen bg-zinc-50 text-zinc-900 antialiased dark:bg-zinc-950 dark:text-zinc-100">
    <div class="flex min-h-screen flex-col md:flex-row">
      <%= render "layouts/sidebar" if authenticated? %>
      <main class="flex-1 overflow-x-hidden">
        <div class="mx-auto max-w-6xl px-6 py-10">
          <%= yield %>
        </div>
      </main>
    </div>
  </body>
```

- [ ] **Step 6: Add the no-flash theme script to the head**

In `app/views/layouts/application.html.erb`, add immediately after `<%= csp_meta_tag %>` (line 10), before `<%= yield :head %>`:

```erb
    <script>
      (function () {
        var m = document.cookie.match(/(?:^|; )theme=([^;]*)/);
        var theme = m ? decodeURIComponent(m[1]) : null;
        if (theme === "dark" || (!theme && window.matchMedia("(prefers-color-scheme: dark)").matches)) {
          document.documentElement.classList.add("dark");
        }
      })();
    </script>
```

- [ ] **Step 7: Run test to verify it passes**

Run: `bin/rails test test/integration/sidebar_shell_test.rb`
Expected: PASS (5 tests). Note: `authenticated?` is a controller helper method (from the `Authentication` concern) available in views.

- [ ] **Step 8: Commit**

```bash
git add -A && git -c user.name='Claude' -c user.email='noreply@anthropic.com' \
  commit -m "Add foldable side-navigation shell to the application layout"
```

---

## Task 6: Sidebar Stimulus controller (fold, drawer, theme)

**Files:**
- Create: `app/javascript/controllers/sidebar_controller.js`

**Interfaces:**
- Consumes: the markup from Task 5 — targets `aside`, `label`, `backdrop`; actions `toggle`, `open`, `close`, `toggleTheme`. Cookies `sidebar_folded`, `theme`.
- Produces: client-side behavior only. No automated test (no JS test driver in the scaffold); verified manually per the steps below.

- [ ] **Step 1: Implement the controller**

Create `app/javascript/controllers/sidebar_controller.js`:

```js
import { Controller } from "@hotwired/stimulus"

// Persisted, foldable sidebar + mobile drawer + theme toggle.
export default class extends Controller {
  static targets = ["aside", "label", "backdrop"]

  // Desktop: fold/unfold and persist in the sidebar_folded cookie.
  toggle() {
    const folded = this.asideTarget.classList.toggle("md:w-16")
    this.asideTarget.classList.toggle("md:w-60", !folded)
    this.labelTargets.forEach((el) => el.classList.toggle("md:hidden", folded))
    const chevron = this.asideTarget.querySelector("[data-action='sidebar#toggle'] svg")
    if (chevron) chevron.classList.toggle("rotate-180", folded)
    this.#setCookie("sidebar_folded", folded ? "1" : "0")
  }

  // Mobile: slide the drawer in.
  open() {
    this.asideTarget.classList.remove("-translate-x-full")
    if (this.hasBackdropTarget) this.backdropTarget.classList.remove("hidden")
  }

  // Mobile: slide the drawer out.
  close() {
    this.asideTarget.classList.add("-translate-x-full")
    if (this.hasBackdropTarget) this.backdropTarget.classList.add("hidden")
  }

  // Toggle light/dark and persist in the theme cookie.
  toggleTheme() {
    const isDark = document.documentElement.classList.toggle("dark")
    this.#setCookie("theme", isDark ? "dark" : "light")
  }

  #setCookie(name, value) {
    const oneYear = 60 * 60 * 24 * 365
    document.cookie = `${name}=${value}; path=/; max-age=${oneYear}; SameSite=Lax`
  }
}
```

- [ ] **Step 2: Manual verification (desktop fold)**

The user runs the app in Docker. Ask them to load the app on a desktop-width window and confirm: clicking the chevron collapses the sidebar to icons only, the chevron flips, labels disappear; reloading the page (hard refresh) keeps it collapsed. Document the result; do not start the server yourself.

- [ ] **Step 3: Manual verification (mobile drawer + theme)**

Ask the user to confirm at a phone width: the hamburger opens the drawer over a dimmed backdrop, tapping the backdrop or a link closes it; the footer theme button flips light/dark and survives a reload. Document the result.

- [ ] **Step 4: Commit**

```bash
git add -A && git -c user.name='Claude' -c user.email='noreply@anthropic.com' \
  commit -m "Add Stimulus controller for sidebar fold, mobile drawer, and theme toggle"
```

---

## Task 7: Convert dashboard and sign-in views to light/dark

**Files:**
- Modify: `app/views/dashboard/index.html.erb`, `app/views/sessions/new.html.erb`
- Test: existing `test/controllers/sessions_controller_test.rb` (must still pass)

**Interfaces:**
- Consumes: the shell layout from Task 5 (dashboard now renders inside `<main>`, so it drops its own header/sign-out).
- Produces: nothing new; visual parity in both themes.

- [ ] **Step 1: Rewrite the dashboard view (remove its own header/sign-out — now in the sidebar)**

Replace the entire contents of `app/views/dashboard/index.html.erb` with:

```erb
<% content_for :title, "hunter — Dashboard" %>

<div class="flex items-center gap-2">
  <h1 class="text-2xl font-semibold text-zinc-900 dark:text-zinc-100">Dashboard</h1>
  <span class="rounded bg-indigo-600/10 px-1.5 py-0.5 text-xs font-medium text-indigo-600 dark:bg-indigo-600/20 dark:text-indigo-400">beta</span>
</div>
<p class="mt-2 text-zinc-500 dark:text-zinc-400">
  Welcome to hunter, <%= Current.user&.username %>. Vulnerability management features are coming next.
</p>

<div class="mt-8 rounded-lg border border-zinc-200 bg-white p-6 dark:border-zinc-800 dark:bg-zinc-900/40">
  <p class="text-sm text-zinc-500 dark:text-zinc-500">
    You are signed in. PostgreSQL, Rails, and Tailwind are wired up. The
    MongoDB-backed vulnerability API will be added in a later pass.
  </p>
</div>
```

- [ ] **Step 2: Convert the sign-in view to light/dark**

The sign-in page renders OUTSIDE the authenticated shell (no sidebar). Replace the contents of `app/views/sessions/new.html.erb` with:

```erb
<div class="-mx-6 -my-10 flex min-h-screen items-center justify-center px-4">
  <div class="w-full max-w-sm">
    <div class="mb-8 text-center">
      <h1 class="text-3xl font-bold tracking-tight text-zinc-900 dark:text-zinc-100">hunter</h1>
      <p class="mt-1 text-sm text-zinc-500">Vulnerability management</p>
    </div>

    <% if alert = flash[:alert] %>
      <p class="mb-4 rounded-lg border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-700 dark:border-red-900/50 dark:bg-red-950/50 dark:text-red-400" id="alert"><%= alert %></p>
    <% end %>

    <% if notice = flash[:notice] %>
      <p class="mb-4 rounded-lg border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm text-emerald-700 dark:border-emerald-900/50 dark:bg-emerald-950/50 dark:text-emerald-400" id="notice"><%= notice %></p>
    <% end %>

    <%= form_with url: session_url, class: "space-y-4" do |form| %>
      <div>
        <%= form.label :username, class: "block text-sm font-medium text-zinc-600 dark:text-zinc-400 mb-1" %>
        <%= form.text_field :username, required: true, autofocus: true, autocomplete: "username", placeholder: "admin", value: params[:username],
              class: "block w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-zinc-900 placeholder-zinc-400 focus:border-indigo-500 focus:outline-none focus:ring-1 focus:ring-indigo-500 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-100 dark:placeholder-zinc-600" %>
      </div>

      <div>
        <%= form.label :password, class: "block text-sm font-medium text-zinc-600 dark:text-zinc-400 mb-1" %>
        <%= form.password_field :password, required: true, autocomplete: "current-password", placeholder: "••••••••", maxlength: 72,
              class: "block w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-zinc-900 placeholder-zinc-400 focus:border-indigo-500 focus:outline-none focus:ring-1 focus:ring-indigo-500 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-100 dark:placeholder-zinc-600" %>
      </div>

      <%= form.submit "Sign in",
            class: "w-full cursor-pointer rounded-md bg-indigo-600 px-3.5 py-2.5 text-center font-medium text-white hover:bg-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-offset-2 dark:focus:ring-offset-zinc-950" %>
    <% end %>
  </div>
</div>
```

- [ ] **Step 3: Run the full suite to verify no regressions**

Run: `bin/rails test`
Expected: PASS (all tests, including sessions + the new navigation/helper/shell tests).

- [ ] **Step 4: Manual verification**

Ask the user to confirm in Docker: dashboard and sign-in look correct in both light and dark mode, sign-out from the sidebar works, and the sign-in page (unauthenticated) shows no sidebar. Document the result.

- [ ] **Step 5: Commit**

```bash
git add -A && git -c user.name='Claude' -c user.email='noreply@anthropic.com' \
  commit -m "Convert dashboard and sign-in views to light and dark themes"
```

---

## Self-Review Notes

- **Spec coverage:** app shell/two-column (T5); sidebar structure + groups + active state + tooltips (T5); fold toggle + cookie + server first-paint (T5/T6); JS bootstrap (T4); mobile drawer (T5/T6); class-based dark mode + no-flash script + manual toggle defaulting to system preference (T4/T5/T6); placeholder routes/pages (T1); Heroicons via helper (T2); testing — controller + integration tests (T1/T5), JS verified manually (T6). All spec sections map to a task.
- **Addition beyond spec:** a **Sign out** control was added to the sidebar footer to preserve the sign-out that lived in the old dashboard header (the design didn't place it). Flag for the user during review.
- **Theme first-paint split:** fold state is server-rendered (known default = unfolded); theme is applied by the inline script only (server can't read `prefers-color-scheme`). This avoids a server/client class conflict.
