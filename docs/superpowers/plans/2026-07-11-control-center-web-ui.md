# Control Center Web UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Control Center web department — a tabbed Templates/Jobs UI plus a health badge — that consumes the existing Control Center JSON API, and add a local RabbitMQ so a submitted job is visibly delivered to a channel.

**Architecture:** Web → API → services, mirroring Programs/Vulnerabilities. A `ControlCenter::BaseController` (Department concern + `TABS`) fronts two thin server-rendered shells (`templates#index`, `jobs#index`). Each shell hydrates client-side from one API endpoint via one Stimulus controller; a shared `apiFetch` helper handles JSON + CSRF. A `rabbitmq:3-management` compose service receives published jobs.

**Tech Stack:** Ruby 3.3.6, Rails 8.1, Hotwire (importmap + Stimulus), Tailwind v4, Minitest, docker-compose, RabbitMQ.

## Global Constraints

- Namespacing: web controllers `ControlCenter::` under `app/controllers/control_center/`; views under `app/views/control_center/`; the JSON API stays under the separate `Api::V1::ControlCenter::` namespace. Do not blend into general app code.
- The UI is a pure API consumer: no new API endpoints, services, or models.
- Rows/cells built from API data MUST use `createElement` + `textContent` (never `innerHTML` with interpolated data) — matches `programs_monitor_controller.js`.
- Non-GET fetches send `X-CSRF-Token` from `<meta name="csrf-token">` (present via `csrf_meta_tags` in the layout).
- Design language: monochrome zinc/black Tailwind + dark mode (`dark:`), heroicons via the `heroicon` helper. Only functional status uses color: emerald (ok/succeeded) / rose (down/failed) / zinc (pending). Available heroicons for this work: `play`, `trash`, `clock`, `check`, `x-mark`, `magnifying-glass`, `chevron-down` (there is no `plus`/`paper-airplane` — use text buttons).
- Commit author: `Claude <noreply@anthropic.com>`. Commit messages: a single sentence.
- Tests: `bin/rails test` from `web/`. Needs a reachable Postgres `hunter_test`. Use `sign_in_as(@user)` + `users(:one)` from the test suite. JS has no test harness — JS is verified by the integration tests' wiring assertions plus the manual checklist in Task 6 (the user runs Docker).

---

### Task 1: Department skeleton — routes, controllers, shells, nav

Convert the Control Center stub into a real department with two tabs that render. No client hydration yet — just the navigable shells.

**Files:**
- Modify: `web/config/routes.rb` (swap the stub `get "control_center"` for a `namespace :control_center` web block)
- Create: `web/app/controllers/control_center/base_controller.rb`
- Create: `web/app/controllers/control_center/templates_controller.rb`
- Create: `web/app/controllers/control_center/jobs_controller.rb`
- Create: `web/app/views/control_center/templates/index.html.erb`
- Create: `web/app/views/control_center/jobs/index.html.erb`
- Delete: `web/app/controllers/control_center_controller.rb`
- Delete: `web/app/views/control_center/index.html.erb`
- Modify: `web/app/helpers/navigation_helper.rb` (repoint the Control Center link)
- Test: `web/test/integration/control_center/tabs_test.rb`

**Interfaces:**
- Produces: route helpers `control_center_root_path` (Templates) and `control_center_jobs_path` (Jobs); controller constant `ControlCenter::BaseController::TABS`.

- [ ] **Step 1: Write the failing test**

`web/test/integration/control_center/tabs_test.rb`:

```ruby
require "test_helper"

class ControlCenter::TabsTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }

  test "templates and jobs redirect an unauthenticated visitor to sign in" do
    get control_center_root_path
    assert_redirected_to new_session_path
    get control_center_jobs_path
    assert_redirected_to new_session_path
  end

  test "templates page renders with the Templates tab active" do
    sign_in_as(@user)
    get control_center_root_path
    assert_response :success
    assert_select "a[href=?][aria-current=page]", control_center_root_path, text: "Templates"
    assert_select "a[href=?]:not([aria-current])", control_center_jobs_path, text: "Jobs"
  end

  test "jobs page renders with the Jobs tab active" do
    sign_in_as(@user)
    get control_center_jobs_path
    assert_response :success
    assert_select "a[href=?][aria-current=page]", control_center_jobs_path, text: "Jobs"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bin/rails test test/integration/control_center/tabs_test.rb`
Expected: FAIL — `undefined local variable or method 'control_center_root_path'` (route not defined).

- [ ] **Step 3: Swap the web route**

In `web/config/routes.rb`, replace the line:

```ruby
  get "control_center", to: "control_center#index"
```

with:

```ruby
  # Control Center web department — Whiterabbit templates + jobs. Tabs are data
  # (ControlCenter::BaseController::TABS); adding one is a one-line change there.
  namespace :control_center do
    get "/",     to: "templates#index", as: :root
    get "/jobs", to: "jobs#index",      as: :jobs
  end
```

- [ ] **Step 4: Write the base + tab controllers**

`web/app/controllers/control_center/base_controller.rb`:

```ruby
module ControlCenter
  # Base for every controller in the Control Center web department. Adding a tab
  # is a one-line change to TABS.
  class BaseController < ApplicationController
    include Department

    TABS = [
      { name: "Templates", path: :control_center_root_path },
      { name: "Jobs",      path: :control_center_jobs_path }
    ].freeze
  end
end
```

`web/app/controllers/control_center/templates_controller.rb`:

```ruby
module ControlCenter
  # Templates tab — a thin shell hydrated from /api/v1/control_center/templates.
  class TemplatesController < BaseController
    def index; end
  end
end
```

`web/app/controllers/control_center/jobs_controller.rb`:

```ruby
module ControlCenter
  # Jobs tab — a thin shell hydrated from /api/v1/control_center/jobs.
  class JobsController < BaseController
    def index; end
  end
end
```

- [ ] **Step 5: Write the shell views**

`web/app/views/control_center/templates/index.html.erb`:

```erb
<% content_for :title, "hunter — Control Center templates" %>
<% content_for :container, "mx-auto max-w-screen-2xl px-6 py-10" %>

<header class="flex items-center gap-3">
  <h1 class="text-2xl font-semibold text-zinc-900 dark:text-zinc-100">Control Center</h1>
  <span class="rounded border border-zinc-300 px-1.5 py-0.5 text-xs font-medium text-zinc-600 dark:border-zinc-700 dark:text-zinc-400">beta</span>
</header>
<p class="mt-1 text-sm text-zinc-500 dark:text-zinc-400">Author Whiterabbit command templates and dispatch jobs.</p>

<%= render "layouts/department_tabs", label: "Control Center sections" %>

<section class="mt-6">
  <p class="text-sm text-zinc-400 dark:text-zinc-500">Templates load here.</p>
</section>
```

`web/app/views/control_center/jobs/index.html.erb`:

```erb
<% content_for :title, "hunter — Control Center jobs" %>
<% content_for :container, "mx-auto max-w-screen-2xl px-6 py-10" %>

<header class="flex items-center gap-3">
  <h1 class="text-2xl font-semibold text-zinc-900 dark:text-zinc-100">Control Center</h1>
  <span class="rounded border border-zinc-300 px-1.5 py-0.5 text-xs font-medium text-zinc-600 dark:border-zinc-700 dark:text-zinc-400">beta</span>
</header>
<p class="mt-1 text-sm text-zinc-500 dark:text-zinc-400">Submission history and job output.</p>

<%= render "layouts/department_tabs", label: "Control Center sections" %>

<section class="mt-6">
  <p class="text-sm text-zinc-400 dark:text-zinc-500">Jobs load here.</p>
</section>
```

- [ ] **Step 6: Remove the old stub controller + view**

Run:
```bash
cd web && git rm app/controllers/control_center_controller.rb app/views/control_center/index.html.erb
```

- [ ] **Step 7: Repoint the sidebar nav link**

In `web/app/helpers/navigation_helper.rb`, change the Control Center entry from:

```ruby
        { label: "Control Center", path: control_center_path, controllers: %w[control_center], icon: "viewfinder-circle" },
```

to:

```ruby
        { label: "Control Center", path: control_center_root_path, controllers: %w[control_center], icon: "viewfinder-circle" },
```

(The `controllers: %w[control_center]` match still works — `nav_active?` matches on the first path segment, which is `control_center` for `control_center/templates` and `control_center/jobs`.)

- [ ] **Step 8: Run the test to verify it passes**

Run: `cd web && bin/rails test test/integration/control_center/tabs_test.rb`
Expected: PASS (3 runs, 0 failures).

- [ ] **Step 9: Commit**

```bash
git add web/config/routes.rb web/app/controllers/control_center web/app/views/control_center web/app/helpers/navigation_helper.rb web/test/integration/control_center/tabs_test.rb
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Add Control Center web department with Templates and Jobs tabs"
```

---

### Task 2: Health badge + shared apiFetch helper

A two-dot RabbitMQ/Mongo health badge in both tab headers, plus the shared `apiFetch` module every Control Center Stimulus controller reuses.

**Files:**
- Create: `web/app/javascript/lib/api_fetch.js`
- Modify: `web/config/importmap.rb` (pin the `lib` folder)
- Create: `web/app/views/control_center/_health.html.erb`
- Create: `web/app/javascript/controllers/control_center_health_controller.js`
- Modify: `web/app/views/control_center/templates/index.html.erb` (render badge in header)
- Modify: `web/app/views/control_center/jobs/index.html.erb` (render badge in header)
- Test: `web/test/integration/control_center/tabs_test.rb` (extend)

**Interfaces:**
- Produces: JS module `lib/api_fetch` exporting `apiFetch(url, { method, body }) -> { ok, status, data }`; Stimulus controller identifier `control-center-health` reading value `url` (`data-control-center-health-url-value`).
- Consumes: `api_v1_control_center_health_path`.

- [ ] **Step 1: Write the failing test (extend tabs_test.rb)**

Add these two tests inside `class ControlCenter::TabsTest`:

```ruby
  test "templates page mounts the health badge wired to the health API" do
    sign_in_as(@user)
    get control_center_root_path
    assert_select "[data-controller~=control-center-health][data-control-center-health-url-value=?]",
                  api_v1_control_center_health_path
  end

  test "jobs page mounts the health badge" do
    sign_in_as(@user)
    get control_center_jobs_path
    assert_select "[data-controller~=control-center-health]"
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bin/rails test test/integration/control_center/tabs_test.rb`
Expected: FAIL — no element with `data-controller~=control-center-health`.

- [ ] **Step 3: Write the apiFetch helper**

`web/app/javascript/lib/api_fetch.js`:

```javascript
// Shared JSON fetch for Control Center Stimulus controllers. Sends the session
// cookie (credentials: same-origin) and, for writes, the X-CSRF-Token from the
// <meta name="csrf-token"> tag — the API's cookie auth path is CSRF-protected.
// Returns { ok, status, data }; data is null for empty bodies (e.g. 204).
export async function apiFetch(url, { method = "GET", body } = {}) {
  const headers = { Accept: "application/json" }
  if (body !== undefined) headers["Content-Type"] = "application/json"
  if (method !== "GET" && method !== "HEAD") {
    const token = document.querySelector('meta[name="csrf-token"]')?.content
    if (token) headers["X-CSRF-Token"] = token
  }
  const res = await fetch(url, {
    method,
    headers,
    credentials: "same-origin",
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  const text = await res.text()
  return { ok: res.ok, status: res.status, data: text ? JSON.parse(text) : null }
}
```

- [ ] **Step 4: Pin the lib folder in importmap**

In `web/config/importmap.rb`, add this line immediately after the existing `pin_all_from "app/javascript/controllers", under: "controllers"`:

```ruby
pin_all_from "app/javascript/lib", under: "lib"
```

- [ ] **Step 5: Write the health Stimulus controller**

`web/app/javascript/controllers/control_center_health_controller.js`:

```javascript
import { Controller } from "@hotwired/stimulus"
import { apiFetch } from "lib/api_fetch"

// Polls /api/v1/control_center/health and colors the RabbitMQ + Mongo dots.
// green = ok, rose = down/error; the detail string becomes the dot's tooltip.
export default class extends Controller {
  static values = { url: String, poll: { type: Number, default: 15000 } }
  static targets = ["rabbitmqDot", "mongoDot"]

  connect() {
    this.refresh()
    this.timer = setInterval(() => this.refresh(), this.pollValue)
  }

  disconnect() {
    if (this.timer) clearInterval(this.timer)
  }

  async refresh() {
    const { ok, data } = await apiFetch(this.urlValue)
    if (!ok || !data) {
      this.paint(this.rabbitmqDotTarget, false, "unreachable")
      this.paint(this.mongoDotTarget, false, "unreachable")
      return
    }
    this.paint(this.rabbitmqDotTarget, data.rabbitmq?.ok, data.rabbitmq?.detail)
    this.paint(this.mongoDotTarget, data.mongo?.ok, data.mongo?.detail)
  }

  paint(dot, up, detail) {
    dot.classList.toggle("bg-emerald-500", !!up)
    dot.classList.toggle("bg-rose-500", !up)
    dot.classList.remove("bg-zinc-300", "dark:bg-zinc-600")
    dot.title = detail || (up ? "ok" : "down")
  }
}
```

- [ ] **Step 6: Write the health partial**

`web/app/views/control_center/_health.html.erb`:

```erb
<%# RabbitMQ + Mongo reachability badge. Hydrates from the health API; the dots
    start neutral (zinc) and turn emerald/rose on the first poll. %>
<div class="flex items-center gap-3 text-xs text-zinc-500 dark:text-zinc-400"
     data-controller="control-center-health"
     data-control-center-health-url-value="<%= api_v1_control_center_health_path %>">
  <span class="inline-flex items-center gap-1.5">
    <span class="h-2 w-2 rounded-full bg-zinc-300 dark:bg-zinc-600"
          data-control-center-health-target="rabbitmqDot"></span>RabbitMQ
  </span>
  <span class="inline-flex items-center gap-1.5">
    <span class="h-2 w-2 rounded-full bg-zinc-300 dark:bg-zinc-600"
          data-control-center-health-target="mongoDot"></span>Mongo
  </span>
</div>
```

- [ ] **Step 7: Render the badge in both headers**

In BOTH `web/app/views/control_center/templates/index.html.erb` and `web/app/views/control_center/jobs/index.html.erb`, replace the `<header>…</header>` block with this version (adds the badge on the right):

```erb
<header class="flex items-center gap-3">
  <h1 class="text-2xl font-semibold text-zinc-900 dark:text-zinc-100">Control Center</h1>
  <span class="rounded border border-zinc-300 px-1.5 py-0.5 text-xs font-medium text-zinc-600 dark:border-zinc-700 dark:text-zinc-400">beta</span>
  <div class="ml-auto"><%= render "control_center/health" %></div>
</header>
```

- [ ] **Step 8: Run the test to verify it passes**

Run: `cd web && bin/rails test test/integration/control_center/tabs_test.rb`
Expected: PASS (5 runs, 0 failures).

- [ ] **Step 9: Commit**

```bash
git add web/app/javascript/lib/api_fetch.js web/config/importmap.rb web/app/views/control_center web/app/javascript/controllers/control_center_health_controller.js web/test/integration/control_center/tabs_test.rb
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Add Control Center health badge and shared apiFetch helper"
```

---

### Task 3: Templates tab — list, editor, validate, CRUD, send job

The Templates tab's full client: list templates, create/edit with live dry-run validation, delete, and dispatch a job from a template.

**Files:**
- Modify: `web/app/views/control_center/templates/index.html.erb` (replace the placeholder `<section>` with the full shell)
- Create: `web/app/javascript/controllers/control_center_templates_controller.js`
- Test: `web/test/integration/control_center/tabs_test.rb` (extend)

**Interfaces:**
- Produces: Stimulus identifier `control-center-templates` with values `indexUrl`, `validateUrl`, `jobsUrl`.
- Consumes: `api_v1_control_center_templates_path`, `validate_api_v1_control_center_templates_path`, `api_v1_control_center_jobs_path`, and `apiFetch` from Task 2.

- [ ] **Step 1: Write the failing test (extend tabs_test.rb)**

Add inside `class ControlCenter::TabsTest`:

```ruby
  test "templates page mounts the templates controller wired to its endpoints" do
    sign_in_as(@user)
    get control_center_root_path
    assert_select "section[data-controller~=control-center-templates]" \
                  "[data-control-center-templates-index-url-value=?]" \
                  "[data-control-center-templates-validate-url-value=?]" \
                  "[data-control-center-templates-jobs-url-value=?]",
                  api_v1_control_center_templates_path,
                  validate_api_v1_control_center_templates_path,
                  api_v1_control_center_jobs_path
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bin/rails test test/integration/control_center/tabs_test.rb`
Expected: FAIL — no `section[data-controller~=control-center-templates]`.

- [ ] **Step 3: Replace the templates shell `<section>`**

In `web/app/views/control_center/templates/index.html.erb`, replace the placeholder section:

```erb
<section class="mt-6">
  <p class="text-sm text-zinc-400 dark:text-zinc-500">Templates load here.</p>
</section>
```

with the full shell:

```erb
<section class="mt-6"
         data-controller="control-center-templates"
         data-control-center-templates-index-url-value="<%= api_v1_control_center_templates_path %>"
         data-control-center-templates-validate-url-value="<%= validate_api_v1_control_center_templates_path %>"
         data-control-center-templates-jobs-url-value="<%= api_v1_control_center_jobs_path %>">

  <div class="mb-3 flex items-center justify-between">
    <button type="button" data-action="control-center-templates#refresh"
            class="inline-flex items-center gap-1.5 rounded-md border border-zinc-300 px-2.5 py-1.5 text-sm font-medium text-zinc-700 hover:bg-zinc-100 dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800">
      <%= heroicon "clock", classes: "h-4 w-4" %> Refresh
    </button>
    <button type="button" data-action="control-center-templates#newTemplate"
            class="inline-flex items-center gap-1.5 rounded-md bg-zinc-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-zinc-700 dark:bg-white dark:text-zinc-900 dark:hover:bg-zinc-200">
      New template
    </button>
  </div>

  <%# --- list --- %>
  <div class="overflow-hidden rounded-lg border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-[#111315]">
    <table class="w-full text-left text-sm">
      <thead class="border-b border-zinc-100 text-xs uppercase tracking-wide text-zinc-500 dark:border-zinc-800 dark:text-zinc-400">
        <tr>
          <th class="px-4 py-2 font-medium">Name</th>
          <th class="px-4 py-2 font-medium">Kind</th>
          <th class="px-4 py-2 font-medium">Commands</th>
          <th class="px-4 py-2 font-medium">Tags</th>
          <th class="px-4 py-2"></th>
        </tr>
      </thead>
      <tbody data-control-center-templates-target="rows" class="divide-y divide-zinc-100 dark:divide-zinc-800/70"></tbody>
    </table>
    <div data-control-center-templates-target="empty" class="hidden px-4 py-12 text-center text-sm text-zinc-400 dark:text-zinc-500">
      No templates yet. Create one to get started.
    </div>
  </div>

  <%# --- editor panel (hidden until New/Edit) --- %>
  <div data-control-center-templates-target="editor"
       class="mt-4 hidden rounded-lg border border-zinc-200 bg-white p-4 dark:border-zinc-800 dark:bg-[#111315]">
    <div class="grid gap-3 sm:grid-cols-2">
      <label class="text-sm">Name
        <input data-control-center-templates-target="fName" data-action="input->control-center-templates#validate"
               class="mt-1 w-full rounded-md border border-zinc-300 bg-white px-2 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-900">
      </label>
      <label class="text-sm">Kind
        <select data-control-center-templates-target="fKind"
                class="mt-1 w-full rounded-md border border-zinc-300 bg-white px-2 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-900">
          <option value="cmdscript">cmdscript</option>
          <option value="workflow">workflow</option>
        </select>
      </label>
      <label class="text-sm">Output file (optional)
        <input data-control-center-templates-target="fOutput"
               class="mt-1 w-full rounded-md border border-zinc-300 bg-white px-2 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-900">
      </label>
      <label class="text-sm">Tags (comma-separated)
        <input data-control-center-templates-target="fTags"
               class="mt-1 w-full rounded-md border border-zinc-300 bg-white px-2 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-900">
      </label>
      <label class="text-sm sm:col-span-2">Description
        <input data-control-center-templates-target="fDescription"
               class="mt-1 w-full rounded-md border border-zinc-300 bg-white px-2 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-900">
      </label>
    </div>

    <div class="mt-3">
      <div class="mb-1 flex items-center justify-between">
        <span class="text-xs font-medium uppercase tracking-wide text-zinc-500 dark:text-zinc-400">Commands</span>
        <button type="button" data-action="control-center-templates#addCommand"
                class="text-xs font-medium text-zinc-600 hover:text-zinc-900 dark:text-zinc-300 dark:hover:text-white">Add command</button>
      </div>
      <div data-control-center-templates-target="commands" class="space-y-2"></div>
    </div>

    <%# Row template cloned by addCommand(). args are whitespace-separated tokens
        (the validator forbids spaces inside an arg, so this is lossless). %>
    <template data-control-center-templates-target="commandRow">
      <div class="flex flex-wrap items-center gap-2" data-row>
        <input placeholder="command" data-field="command" data-action="input->control-center-templates#validate"
               class="w-32 rounded-md border border-zinc-300 bg-white px-2 py-1 text-sm dark:border-zinc-700 dark:bg-zinc-900">
        <input placeholder="args (space-separated)" data-field="args" data-action="input->control-center-templates#validate"
               class="min-w-[12rem] flex-1 rounded-md border border-zinc-300 bg-white px-2 py-1 text-sm dark:border-zinc-700 dark:bg-zinc-900">
        <select data-field="operator" data-action="change->control-center-templates#validate"
                class="rounded-md border border-zinc-300 bg-white px-2 py-1 text-sm dark:border-zinc-700 dark:bg-zinc-900">
          <option value="">(none)</option>
          <option value="|">|</option>
          <option value="&&">&amp;&amp;</option>
          <option value="||">||</option>
        </select>
        <button type="button" data-action="control-center-templates#removeCommand"
                class="rounded p-1 text-zinc-400 hover:text-rose-600" aria-label="Remove command">
          <%= heroicon "trash", classes: "h-4 w-4" %>
        </button>
      </div>
    </template>

    <ul data-control-center-templates-target="errors" class="mt-3 hidden list-disc space-y-1 rounded-md bg-rose-50 px-5 py-2 text-xs text-rose-700 dark:bg-rose-950/40 dark:text-rose-300"></ul>

    <div class="mt-4 flex items-center gap-2">
      <button type="button" data-control-center-templates-target="save" data-action="control-center-templates#save"
              class="inline-flex items-center gap-1.5 rounded-md bg-zinc-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-zinc-700 disabled:opacity-40 dark:bg-white dark:text-zinc-900 dark:hover:bg-zinc-200">
        <%= heroicon "check", classes: "h-4 w-4" %> Save
      </button>
      <button type="button" data-action="control-center-templates#closeEditor"
              class="rounded-md border border-zinc-300 px-3 py-1.5 text-sm font-medium text-zinc-700 hover:bg-zinc-100 dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800">Cancel</button>
    </div>
  </div>

  <%# --- send-job dialog (hidden until Send) --- %>
  <div data-control-center-templates-target="sendDialog"
       class="mt-4 hidden rounded-lg border border-zinc-200 bg-white p-4 dark:border-zinc-800 dark:bg-[#111315]">
    <p class="text-sm font-medium text-zinc-800 dark:text-zinc-100">Send job:
      <span data-control-center-templates-target="sendName" class="font-mono"></span></p>
    <div class="mt-3 grid gap-3 sm:grid-cols-3">
      <label class="text-sm sm:col-span-3">Targets (one per line)
        <textarea rows="4" data-control-center-templates-target="sendTargets"
                  class="mt-1 w-full rounded-md border border-zinc-300 bg-white px-2 py-1.5 font-mono text-sm dark:border-zinc-700 dark:bg-zinc-900"></textarea>
      </label>
      <label class="text-sm">Queue
        <input value="test" data-control-center-templates-target="sendQueue"
               class="mt-1 w-full rounded-md border border-zinc-300 bg-white px-2 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-900">
      </label>
      <label class="text-sm">Target chunk
        <input type="number" value="0" min="0" data-control-center-templates-target="sendChunk"
               class="mt-1 w-full rounded-md border border-zinc-300 bg-white px-2 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-900">
      </label>
      <label class="text-sm">Delay (s)
        <input type="number" value="0" min="0" data-control-center-templates-target="sendDelay"
               class="mt-1 w-full rounded-md border border-zinc-300 bg-white px-2 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-900">
      </label>
    </div>
    <pre data-control-center-templates-target="sendResult" class="mt-3 hidden max-h-48 overflow-auto rounded-md bg-zinc-950 p-3 font-mono text-xs text-zinc-100"></pre>
    <div class="mt-4 flex items-center gap-2">
      <button type="button" data-action="control-center-templates#submitJob"
              class="inline-flex items-center gap-1.5 rounded-md bg-zinc-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-zinc-700 dark:bg-white dark:text-zinc-900 dark:hover:bg-zinc-200">
        <%= heroicon "play", classes: "h-4 w-4" %> Send
      </button>
      <button type="button" data-action="control-center-templates#closeSend"
              class="rounded-md border border-zinc-300 px-3 py-1.5 text-sm font-medium text-zinc-700 hover:bg-zinc-100 dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800">Close</button>
    </div>
  </div>
</section>
```

- [ ] **Step 4: Write the templates Stimulus controller**

`web/app/javascript/controllers/control_center_templates_controller.js`:

```javascript
import { Controller } from "@hotwired/stimulus"
import { apiFetch } from "lib/api_fetch"

// Templates tab: list/create/edit/delete templates and dispatch jobs. All rows
// and cells are built with createElement/textContent so template-supplied
// strings can never inject HTML.
export default class extends Controller {
  static values = { indexUrl: String, validateUrl: String, jobsUrl: String }
  static targets = [
    "rows", "empty", "editor", "commands", "commandRow", "errors", "save",
    "fName", "fKind", "fOutput", "fTags", "fDescription",
    "sendDialog", "sendName", "sendTargets", "sendQueue", "sendChunk", "sendDelay", "sendResult",
  ]

  connect() {
    this.editingId = null
    this.sendTemplate = null
    this.refresh()
  }

  // --- list ----------------------------------------------------------------

  async refresh() {
    const { ok, data } = await apiFetch(this.indexUrlValue)
    const templates = ok && data ? data.templates : []
    this.render(templates)
  }

  render(templates) {
    this.rowsTarget.replaceChildren()
    this.emptyTarget.classList.toggle("hidden", templates.length > 0)
    templates.forEach((t) => this.rowsTarget.appendChild(this.rowFor(t)))
  }

  rowFor(t) {
    const tr = document.createElement("tr")
    tr.appendChild(this.cell(t.name, "px-4 py-2 font-medium text-zinc-900 dark:text-zinc-100"))
    tr.appendChild(this.cell(t.kind, "px-4 py-2 text-zinc-500 dark:text-zinc-400"))
    const summary = (t.commands || []).map((c) => c.command).join(" ")
    tr.appendChild(this.cell(summary, "px-4 py-2 font-mono text-xs text-zinc-600 dark:text-zinc-300"))
    tr.appendChild(this.cell((t.tags || []).join(", "), "px-4 py-2 text-zinc-500 dark:text-zinc-400"))

    const actions = document.createElement("td")
    actions.className = "px-4 py-2 text-right whitespace-nowrap"
    actions.appendChild(this.button("Send", () => this.openSend(t)))
    actions.appendChild(this.button("Edit", () => this.openEditor(t)))
    actions.appendChild(this.button("Delete", () => this.destroy(t), "text-rose-600"))
    tr.appendChild(actions)
    return tr
  }

  cell(text, className) {
    const td = document.createElement("td")
    td.className = className
    td.textContent = text || ""
    return td
  }

  button(label, onClick, extra = "") {
    const b = document.createElement("button")
    b.type = "button"
    b.textContent = label
    b.className = `ml-3 text-sm font-medium text-zinc-600 hover:text-zinc-900 dark:text-zinc-300 dark:hover:text-white ${extra}`
    b.addEventListener("click", onClick)
    return b
  }

  // --- editor --------------------------------------------------------------

  newTemplate() {
    this.editingId = null
    this.fNameTarget.value = ""
    this.fKindTarget.value = "cmdscript"
    this.fOutputTarget.value = ""
    this.fTagsTarget.value = ""
    this.fDescriptionTarget.value = ""
    this.commandsTarget.replaceChildren()
    this.addCommand()
    this.errorsTarget.classList.add("hidden")
    this.editorTarget.classList.remove("hidden")
    this.sendDialogTarget.classList.add("hidden")
    this.validate()
  }

  openEditor(t) {
    this.editingId = t.id
    this.fNameTarget.value = t.name || ""
    this.fKindTarget.value = t.kind || "cmdscript"
    this.fOutputTarget.value = t.output || ""
    this.fTagsTarget.value = (t.tags || []).join(", ")
    this.fDescriptionTarget.value = t.description || ""
    this.commandsTarget.replaceChildren()
    ;(t.commands || []).forEach((c) => this.addCommand(c))
    if (!(t.commands || []).length) this.addCommand()
    this.editorTarget.classList.remove("hidden")
    this.sendDialogTarget.classList.add("hidden")
    this.validate()
  }

  closeEditor() { this.editorTarget.classList.add("hidden") }

  addCommand(command = null) {
    const row = this.commandRowTarget.content.firstElementChild.cloneNode(true)
    if (command) {
      row.querySelector('[data-field=command]').value = command.command || ""
      row.querySelector('[data-field=args]').value = (command.args || []).join(" ")
      row.querySelector('[data-field=operator]').value = command.operator || ""
    }
    this.commandsTarget.appendChild(row)
  }

  removeCommand(event) {
    event.target.closest("[data-row]").remove()
    this.validate()
  }

  collectCommands() {
    return Array.from(this.commandsTarget.querySelectorAll("[data-row]")).map((row) => ({
      command: row.querySelector('[data-field=command]').value.trim(),
      args: row.querySelector('[data-field=args]').value.trim().split(/\s+/).filter(Boolean),
      operator: row.querySelector('[data-field=operator]').value,
    }))
  }

  async validate() {
    const { ok, data } = await apiFetch(this.validateUrlValue, {
      method: "POST",
      body: { commands: this.collectCommands() },
    })
    const errors = ok && data ? data.errors : ["validation request failed"]
    const valid = ok && data && data.valid && this.fNameTarget.value.trim().length > 0
    this.showErrors(valid ? [] : errors)
    this.saveTarget.disabled = !valid
  }

  showErrors(errors) {
    this.errorsTarget.replaceChildren()
    this.errorsTarget.classList.toggle("hidden", errors.length === 0)
    errors.forEach((msg) => {
      const li = document.createElement("li")
      li.textContent = msg
      this.errorsTarget.appendChild(li)
    })
  }

  async save() {
    const body = {
      name: this.fNameTarget.value.trim(),
      kind: this.fKindTarget.value,
      output: this.fOutputTarget.value.trim(),
      description: this.fDescriptionTarget.value,
      tags: this.fTagsTarget.value.split(",").map((s) => s.trim()).filter(Boolean),
      commands: this.collectCommands(),
    }
    const url = this.editingId ? `${this.indexUrlValue}/${this.editingId}` : this.indexUrlValue
    const method = this.editingId ? "PATCH" : "POST"
    const { ok, data } = await apiFetch(url, { method, body })
    if (ok) {
      this.closeEditor()
      this.refresh()
    } else {
      this.showErrors((data && data.detail) || ["save failed"])
    }
  }

  async destroy(t) {
    if (!window.confirm(`Delete template "${t.name}"?`)) return
    await apiFetch(`${this.indexUrlValue}/${t.id}`, { method: "DELETE" })
    this.refresh()
  }

  // --- send job ------------------------------------------------------------

  openSend(t) {
    this.sendTemplate = t
    this.sendNameTarget.textContent = t.name
    this.sendTargetsTarget.value = ""
    this.sendQueueTarget.value = "test"
    this.sendChunkTarget.value = "0"
    this.sendDelayTarget.value = "0"
    this.sendResultTarget.classList.add("hidden")
    this.sendResultTarget.textContent = ""
    this.sendDialogTarget.classList.remove("hidden")
    this.editorTarget.classList.add("hidden")
  }

  closeSend() { this.sendDialogTarget.classList.add("hidden") }

  async submitJob() {
    const body = {
      template: this.sendTemplate.name,
      targets: this.sendTargetsTarget.value.split("\n").map((s) => s.trim()).filter(Boolean),
      queue_name: this.sendQueueTarget.value.trim() || "test",
      target_chunk: Number(this.sendChunkTarget.value) || 0,
      delay: Number(this.sendDelayTarget.value) || 0,
    }
    const { ok, data } = await apiFetch(this.jobsUrlValue, { method: "POST", body })
    this.sendResultTarget.classList.remove("hidden")
    if (ok && data) {
      this.sendResultTarget.textContent =
        `status: ${data.status}\nexit: ${data.exit_status}\n\n${data.stdout || ""}${data.stderr || ""}`
    } else {
      this.sendResultTarget.textContent = `error: ${JSON.stringify((data && data.detail) || "submit failed")}`
    }
  }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd web && bin/rails test test/integration/control_center/tabs_test.rb`
Expected: PASS (6 runs, 0 failures).

- [ ] **Step 6: Commit**

```bash
git add web/app/views/control_center/templates/index.html.erb web/app/javascript/controllers/control_center_templates_controller.js web/test/integration/control_center/tabs_test.rb
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Add Control Center templates tab client with editor, validation, and job dispatch"
```

---

### Task 4: Jobs tab — history list + detail

The Jobs tab's client: list submission history and expand a row into its stdout/stderr.

**Files:**
- Modify: `web/app/views/control_center/jobs/index.html.erb` (replace the placeholder `<section>`)
- Create: `web/app/javascript/controllers/control_center_jobs_controller.js`
- Test: `web/test/integration/control_center/tabs_test.rb` (extend)

**Interfaces:**
- Produces: Stimulus identifier `control-center-jobs` with value `indexUrl`.
- Consumes: `api_v1_control_center_jobs_path`, `apiFetch`.

- [ ] **Step 1: Write the failing test (extend tabs_test.rb)**

Add inside `class ControlCenter::TabsTest`:

```ruby
  test "jobs page mounts the jobs controller wired to its endpoint" do
    sign_in_as(@user)
    get control_center_jobs_path
    assert_select "section[data-controller~=control-center-jobs]" \
                  "[data-control-center-jobs-index-url-value=?]",
                  api_v1_control_center_jobs_path
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bin/rails test test/integration/control_center/tabs_test.rb`
Expected: FAIL — no `section[data-controller~=control-center-jobs]`.

- [ ] **Step 3: Replace the jobs shell `<section>`**

In `web/app/views/control_center/jobs/index.html.erb`, replace the placeholder section:

```erb
<section class="mt-6">
  <p class="text-sm text-zinc-400 dark:text-zinc-500">Jobs load here.</p>
</section>
```

with:

```erb
<section class="mt-6"
         data-controller="control-center-jobs"
         data-control-center-jobs-index-url-value="<%= api_v1_control_center_jobs_path %>">

  <div class="mb-3 flex justify-end">
    <button type="button" data-action="control-center-jobs#refresh"
            class="inline-flex items-center gap-1.5 rounded-md border border-zinc-300 px-2.5 py-1.5 text-sm font-medium text-zinc-700 hover:bg-zinc-100 dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800">
      <%= heroicon "clock", classes: "h-4 w-4" %> Refresh
    </button>
  </div>

  <div class="overflow-hidden rounded-lg border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-[#111315]">
    <table class="w-full text-left text-sm">
      <thead class="border-b border-zinc-100 text-xs uppercase tracking-wide text-zinc-500 dark:border-zinc-800 dark:text-zinc-400">
        <tr>
          <th class="px-4 py-2 font-medium">Template</th>
          <th class="px-4 py-2 font-medium">Queue</th>
          <th class="px-4 py-2 font-medium">Targets</th>
          <th class="px-4 py-2 font-medium">Status</th>
          <th class="px-4 py-2 font-medium">When</th>
        </tr>
      </thead>
      <tbody data-control-center-jobs-target="rows" class="divide-y divide-zinc-100 dark:divide-zinc-800/70"></tbody>
    </table>
    <div data-control-center-jobs-target="empty" class="hidden px-4 py-12 text-center text-sm text-zinc-400 dark:text-zinc-500">
      No jobs submitted yet.
    </div>
  </div>

  <pre data-control-center-jobs-target="detail" class="mt-4 hidden max-h-64 overflow-auto rounded-lg bg-zinc-950 p-4 font-mono text-xs text-zinc-100"></pre>
</section>
```

- [ ] **Step 4: Write the jobs Stimulus controller**

`web/app/javascript/controllers/control_center_jobs_controller.js`:

```javascript
import { Controller } from "@hotwired/stimulus"
import { apiFetch } from "lib/api_fetch"

// Jobs tab: submission history + a stdout/stderr detail panel. Rows are built
// with createElement/textContent. Submit is synchronous server-side, so a job
// arrives here already succeeded/failed — a manual Refresh is enough.
export default class extends Controller {
  static values = { indexUrl: String }
  static targets = ["rows", "empty", "detail"]

  connect() { this.refresh() }

  async refresh() {
    const { ok, data } = await apiFetch(this.indexUrlValue)
    const jobs = ok && data ? data.jobs : []
    this.rowsTarget.replaceChildren()
    this.emptyTarget.classList.toggle("hidden", jobs.length > 0)
    jobs.forEach((j) => this.rowsTarget.appendChild(this.rowFor(j)))
  }

  rowFor(j) {
    const tr = document.createElement("tr")
    tr.className = "cursor-pointer hover:bg-zinc-50 dark:hover:bg-zinc-800/40"
    tr.addEventListener("click", () => this.showDetail(j.id))
    tr.appendChild(this.cell(j.template_name, "px-4 py-2 font-medium text-zinc-900 dark:text-zinc-100"))
    tr.appendChild(this.cell(j.queue_name, "px-4 py-2 text-zinc-500 dark:text-zinc-400"))
    tr.appendChild(this.cell(String(j.target_count), "px-4 py-2 text-zinc-500 dark:text-zinc-400"))
    tr.appendChild(this.statusCell(j.status))
    tr.appendChild(this.cell(this.time(j.created_at), "px-4 py-2 text-zinc-500 dark:text-zinc-400"))
    return tr
  }

  cell(text, className) {
    const td = document.createElement("td")
    td.className = className
    td.textContent = text || ""
    return td
  }

  statusCell(status) {
    const td = document.createElement("td")
    td.className = "px-4 py-2"
    const badge = document.createElement("span")
    const tone = {
      succeeded: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950/50 dark:text-emerald-300",
      failed: "bg-rose-100 text-rose-800 dark:bg-rose-950/50 dark:text-rose-300",
      pending: "bg-zinc-100 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300",
    }[status] || "bg-zinc-100 text-zinc-600"
    badge.className = `rounded px-1.5 py-0.5 text-xs font-medium ${tone}`
    badge.textContent = status || "unknown"
    td.appendChild(badge)
    return td
  }

  time(iso) {
    if (!iso) return ""
    const d = new Date(iso)
    return Number.isNaN(d.getTime()) ? iso : d.toLocaleString()
  }

  async showDetail(id) {
    const { ok, data } = await apiFetch(`${this.indexUrlValue}/${id}`)
    if (!ok || !data) return
    this.detailTarget.classList.remove("hidden")
    this.detailTarget.textContent =
      `${data.template_name} — ${data.status} (exit ${data.exit_status})\n\n` +
      `$ stdout\n${data.stdout || ""}\n\n$ stderr\n${data.stderr || ""}`
  }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd web && bin/rails test test/integration/control_center/tabs_test.rb`
Expected: PASS (7 runs, 0 failures).

- [ ] **Step 6: Commit**

```bash
git add web/app/views/control_center/jobs/index.html.erb web/app/javascript/controllers/control_center_jobs_controller.js web/test/integration/control_center/tabs_test.rb
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Add Control Center jobs tab client with history list and output detail"
```

---

### Task 5: Dummy RabbitMQ broker in docker-compose

Add a real RabbitMQ (management image) so a submitted job is delivered to a channel and visible in the management UI. Credentials come from the compose env already wired in the API plan.

**Files:**
- Modify: `docker-compose.yaml` (add `rabbitmq` service; add `web` dependency)
- Modify: `.env.example` (give the RabbitMQ credentials non-empty defaults)

**Interfaces:**
- Produces: a `rabbitmq` service reachable at host `rabbitmq:5672` (AMQP) and `localhost:15672` (management UI); the `whiterabbit` binary (already reading `RABBITMQ_*`) publishes to it.

- [ ] **Step 1: Add the rabbitmq service**

In `docker-compose.yaml`, add this service alongside `db:` and `mongo:` (before `web:`):

```yaml
  # Local broker so Control Center job submissions land on a visible channel.
  # Management UI at http://localhost:15672 (same credentials as below).
  rabbitmq:
    image: rabbitmq:3-management
    environment:
      RABBITMQ_DEFAULT_USER: ${RABBITMQ_USERNAME:-hunter}
      RABBITMQ_DEFAULT_PASS: ${RABBITMQ_PASSWORD:-hunter}
    ports:
      - "127.0.0.1:5672:5672"
      - "127.0.0.1:15672:15672"
    healthcheck:
      test: ["CMD", "rabbitmq-diagnostics", "-q", "ping"]
      interval: 10s
      timeout: 5s
      retries: 10
```

- [ ] **Step 2: Make web depend on rabbitmq**

In `docker-compose.yaml`, under the `web:` service's existing `depends_on:` map (which already lists `db` and `mongo`), add:

```yaml
      rabbitmq:
        condition: service_healthy
```

- [ ] **Step 3: Give the RabbitMQ credentials non-empty defaults**

In `.env.example`, replace the existing block:

```
RABBITMQ_USERNAME=
RABBITMQ_PASSWORD=
```

with:

```
RABBITMQ_USERNAME=hunter
RABBITMQ_PASSWORD=hunter
```

(The broker's `RABBITMQ_DEFAULT_USER/PASS` and the binary's `RABBITMQ_USERNAME/PASSWORD` now share one value, so a submitted job authenticates out of the box.)

- [ ] **Step 4: Verify compose parses (non-serving check)**

Run: `docker compose config >/dev/null && echo OK` (if Docker is available). If Docker is not installed in this environment, visually confirm: the `rabbitmq:` service has `image`, `environment` (both `RABBITMQ_DEFAULT_USER`/`PASS`), `ports` (5672 + 15672), and `healthcheck`; and `web.depends_on` lists `rabbitmq: { condition: service_healthy }`. The user runs the actual `docker compose up`.
Expected: no YAML/schema errors.

- [ ] **Step 5: Commit**

```bash
git add docker-compose.yaml .env.example
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Add a local RabbitMQ broker for Control Center job delivery"
```

---

### Task 6: Full-suite green + manual verification checklist

**Files:** none (verification).

- [ ] **Step 1: Run the whole suite**

Run: `cd web && bin/rails test`
Expected: all tests pass, including `test/integration/control_center/tabs_test.rb` (7 runs). If a pre-existing unrelated failure appears (e.g. the known `test/integration/api/runner/jobs_test.rb` load error referencing the missing `Api::Runner::JobsController`), note it but do not fix it here; re-run excluding that file to confirm the department tests are green:
`files=$(find test -name '*_test.rb' ! -path 'test/integration/api/runner/*'); bin/rails test $files`

- [ ] **Step 2: Confirm importmap resolves the new modules**

Run: `cd web && bin/rails runner 'Rails.application.config.importmap.packages; puts "ok"'` then `bin/importmap json | grep -E "lib/api_fetch|control-center|control_center"` (the controllers pin resolves `control_center_*_controller.js` automatically; `lib/api_fetch` must appear).
Expected: `lib/api_fetch` present in the importmap JSON.

- [ ] **Step 3: Manual verification (the user runs Docker)**

Document these steps for the user (no automated test — there is no JS/browser harness in the repo):

1. `cp .env.example .env` (if not already), then `docker compose up --build`.
2. Visit `/control_center` → the header health badge's RabbitMQ + Mongo dots turn green.
3. Click **New template**: name `probe`, one command `httpx` with args `-silent`; the error list clears and **Save** enables. Save → the row appears.
4. Click **Send** on the row: paste a couple of targets, queue `test`, **Send** → the result pane shows `status: succeeded`.
5. Open the **Jobs** tab → the job is listed as `succeeded`; click it → stdout/stderr detail.
6. Open the RabbitMQ management UI at `http://localhost:15672` (login with `RABBITMQ_USERNAME`/`RABBITMQ_PASSWORD`) → the `test` queue shows the delivered message(s).

---

## Self-Review

**Spec coverage:**
- Routes/base controller/`TABS`/thin shells → Task 1.
- `apiFetch` + CSRF + importmap pin → Task 2.
- Health badge partial + poller → Task 2.
- Templates tab (list, editor, live validate, CRUD, send-job dialog) → Task 3.
- Jobs tab (history + detail) → Task 4.
- Sidebar/nav repoint → Task 1 (Step 7).
- Remove old `ControlCenterController`/view → Task 1 (Step 6).
- Dummy RabbitMQ + `.env.example` defaults → Task 5.
- Web department integration tests → Tasks 1–4; manual checklist → Task 6.
- Monochrome + functional-color-only design language → applied in every view step.

**Placeholder scan:** none — every step ships concrete code/commands. JS behaviour (no repo harness) is covered by integration wiring assertions + the Task 6 manual checklist, stated explicitly rather than left implicit.

**Type consistency:** Stimulus identifiers/values are consistent: `control-center-health` (`url`), `control-center-templates` (`indexUrl`/`validateUrl`/`jobsUrl`), `control-center-jobs` (`indexUrl`). `apiFetch(url, {method, body}) -> {ok, status, data}` used identically in Tasks 2–4. Serialization keys consumed by the JS (`templates[]`, `template.commands[].command/args/operator`, `jobs[]`, `job.status/exit_status/stdout/stderr/created_at`, `health.rabbitmq/mongo.{ok,detail}`) match the API controllers' `serialize` output from the API plan. Route helpers (`control_center_root_path`, `control_center_jobs_path`, `api_v1_control_center_*`) verified against `routes.rb`.

**Deviation from spec:** none. Workers tab remains out of scope (API limitation), as stated in the spec's non-goals.
```
