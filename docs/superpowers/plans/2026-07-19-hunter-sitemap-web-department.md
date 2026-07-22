# Hunter Sitemap Web Department Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `/sitemap` web department showing each target origin as a top-level folder that expands into a Caido-style path tree of its crawled endpoints, with a minimal endpoint detail panel.

**Architecture:** A pure `Sitemap::Tree` service turns a target's active endpoints into a nested path trie. A namespaced `Sitemap` department (mirroring CVE/Target) renders the origin list, lazy-loads each origin's full tree into a Turbo Frame on expand (client-side toggle thereafter), and loads an endpoint detail fragment on click. One self-contained `sitemap_tree_controller.js` owns all interactivity; the status pill is local ERB — no dependency on the uncommitted Targets module.

**Tech Stack:** Ruby 3.3.6, Rails 8, Tailwind v4, importmap + Stimulus/Turbo (Hotwire), Minitest. Postgres-only (no Mongo in this department).

## Global Constraints

- Namespace `Sitemap::`; web controllers under `web/app/controllers/sitemap/`, views under `web/app/views/sitemap/`, service under `web/app/services/sitemap/`.
- Read-only view over existing `sitemap_targets` / `sitemap_endpoints`. **No schema changes.**
- **Active rows only** (`removed_at IS NULL`) via the models' `.active` scope.
- Web-controller 404 convention: `head :not_found` (not the API's `render_not_found`).
- Department wiring uses the committed `Department` concern (`app/controllers/concerns/department.rb`); a controller declares `TABS = [{ name:, path: <route-helper symbol> }]`.
- Self-contained: all tree/detail interactivity in the new `sitemap_tree_controller.js`; status shown via inline ERB. Do **not** depend on the Targets module's `rowlink`/`side_panel`/`copyable`/`_status_badge`.
- Commit author `Claude <noreply@anthropic.com>`; commit messages a single sentence.
- `# web/...` comment lines atop code blocks below are FILE LOCATORS, not literal source to write into files.
- `navigation_helper.rb` and `icon_helper.rb` are tracked but already carry unrelated uncommitted edits (Target/CVE sidebar) — when committing, `git add` ONLY the specific files each task changed; never `git add -A`. If a task edits these two files, note in its report that they were left with their pre-existing uncommitted changes intact (add them to the commit only if the whole file's diff is this task's — otherwise leave them uncommitted and say so).
- Tests: run from `web/` with `bin/rails test`. Postgres `hunter_test` is reachable; Mongo is NOT needed here. Ignore boot-time `MONGODB ... Connection refused` warnings.

---

### Task 1: `Sitemap::Tree` path-trie builder

**Files:**
- Create: `web/app/services/sitemap/tree.rb`
- Test: `web/test/services/sitemap/tree_test.rb`

**Interfaces:**
- Consumes: nothing (pure).
- Produces:
  - `Sitemap::Tree.build(endpoints) -> Array<Sitemap::Tree::Node>` (root-level nodes). `endpoints` is any enumerable of objects responding to `#id`, `#path`, `#method`, `#status_code`.
  - `Sitemap::Tree::Node` = `Struct(:label, :full_path, :endpoint, :children)` with `#folder?` (`children.any?`) and `#endpoint?` (`!endpoint.nil?`). `endpoint` is the terminating endpoint object (or nil).

- [ ] **Step 1: Write the failing test**

```ruby
# web/test/services/sitemap/tree_test.rb
require "test_helper"

class Sitemap::TreeTest < ActiveSupport::TestCase
  Ep = Struct.new(:id, :path, :method, :status_code)

  def build(*paths)
    eps = paths.each_with_index.map { |p, i| Ep.new(i + 1, p, "GET", 200) }
    Sitemap::Tree.build(eps)
  end

  test "a single leaf endpoint" do
    nodes = build("/about")
    assert_equal ["about"], nodes.map(&:label)
    n = nodes.first
    assert_equal "/about", n.full_path
    assert n.endpoint?
    refute n.folder?
  end

  test "nested folders with a leaf" do
    nodes = build("/_nuxt/app.js")
    folder = nodes.sole
    assert_equal "_nuxt/", folder.label
    assert folder.folder?
    refute folder.endpoint?
    leaf = folder.children.sole
    assert_equal "app.js", leaf.label
    assert_equal "/_nuxt/app.js", leaf.full_path
    assert leaf.endpoint?
  end

  test "trailing slash makes /about and /about/ distinct siblings" do
    nodes = build("/about", "/about/x")
    labels = nodes.map(&:label)
    assert_includes labels, "about"       # leaf request
    assert_includes labels, "about/"      # implied directory
    dir = nodes.find { |n| n.label == "about/" }
    assert_equal ["x"], dir.children.map(&:label)
  end

  test "a node can be both a folder and an endpoint" do
    nodes = build("/api/", "/api/users")
    api = nodes.sole
    assert_equal "api/", api.label
    assert api.folder?
    assert api.endpoint?, "/api/ is itself a request"
    assert_equal ["users"], api.children.map(&:label)
  end

  test "root request attaches to a '/' node" do
    nodes = build("/")
    assert_equal ["/"], nodes.map(&:label)
    assert nodes.first.endpoint?
  end

  test "sort: folders before leaves, each alphabetical (case-insensitive)" do
    nodes = build("/zebra", "/Alpha/x", "/beta")
    assert_equal ["Alpha/", "beta", "zebra"], nodes.map(&:label)
  end

  test "same path different method collapses to one node (lowest id wins)" do
    eps = [Ep.new(2, "/x", "POST", 201), Ep.new(1, "/x", "GET", 200)]
    node = Sitemap::Tree.build(eps).sole
    assert_equal 1, node.endpoint.id
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bin/rails test test/services/sitemap/tree_test.rb`
Expected: FAIL — `uninitialized constant Sitemap::Tree`.

- [ ] **Step 3: Write the implementation**

```ruby
# web/app/services/sitemap/tree.rb
module Sitemap
  # Turns a flat list of endpoints into a nested path-segment tree (a trie),
  # mirroring the Burp/Caido site tree. Pure: no DB, no view concerns. Consumers
  # pass any objects responding to #id/#path/#method/#status_code.
  module Tree
    module_function

    Node = Struct.new(:label, :full_path, :endpoint, :children, keyword_init: true) do
      def folder?   = children.any?
      def endpoint? = !endpoint.nil?
    end

    # Root-level nodes, sorted (folders first, then leaves; each alphabetical).
    def build(endpoints)
      root = {}
      endpoints.sort_by(&:id).each { |ep| insert(root, ep) }
      to_nodes(root)
    end

    # --- internals ---

    def insert(root, endpoint)
      path = endpoint.path.to_s
      path = "/#{path}" unless path.start_with?("/")
      parts = path.sub(%r{\A/}, "").split("/")

      if parts.empty? # the "/" root request
        e = (root["/"] ||= entry("/", "/"))
        e[:endpoint] ||= endpoint
        return
      end

      dir = path.end_with?("/")
      level = root
      full = ""
      parts.each_with_index do |part, i|
        last = i == parts.length - 1
        is_dir = last ? dir : true
        label = is_dir ? "#{part}/" : part
        full = "#{full}/#{part}#{is_dir ? '/' : ''}"
        e = (level[label] ||= entry(label, full))
        e[:endpoint] ||= endpoint if last
        level = e[:children]
      end
    end
    private_class_method :insert

    def entry(label, full) = { label: label, full_path: full, endpoint: nil, children: {} }
    private_class_method :entry

    def to_nodes(level)
      nodes = level.values.map do |e|
        Node.new(label: e[:label], full_path: e[:full_path], endpoint: e[:endpoint],
                 children: to_nodes(e[:children]))
      end
      nodes.sort_by { |n| [n.folder? ? 0 : 1, n.label.downcase] }
    end
    private_class_method :to_nodes
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bin/rails test test/services/sitemap/tree_test.rb`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add web/app/services/sitemap/tree.rb web/test/services/sitemap/tree_test.rb
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Add Sitemap::Tree path-trie builder"
```

---

### Task 2: Department shell — routes, controllers, origin list, sidebar

**Files:**
- Create: `web/app/controllers/sitemap/base_controller.rb`
- Create: `web/app/controllers/sitemap/origins_controller.rb`
- Create: `web/app/views/sitemap/origins/index.html.erb`
- Create: `web/app/views/sitemap/origins/_origin.html.erb`
- Modify: `web/config/routes.rb` (add the `namespace :sitemap` block)
- Modify: `web/app/helpers/navigation_helper.rb` (add the sidebar entry)
- Modify: `web/app/helpers/icon_helper.rb` (add a `"sitemap"` icon)
- Test: `web/test/integration/sitemap/origins_test.rb`

**Interfaces:**
- Consumes: `Sitemap::Target` (`.active`, `origin/scheme/host/port`), `Sitemap::Endpoint` (`.active`), `Department` concern.
- Produces:
  - Routes: `sitemap_root_path`, `sitemap_origin_tree_path(id)`, `sitemap_endpoint_path(id)`.
  - `Sitemap::OriginsController#index` sets `@q`, `@targets` (active, ordered by host,port, host-filtered by `@q`), `@counts` (target_id → active endpoint count).
  - `_origin` partial renders one origin folder row wrapping an empty lazy Turbo Frame `origin_tree_<id>` carrying `data-src` = `sitemap_origin_tree_path(target)`.

- [ ] **Step 1: Write the failing test**

```ruby
# web/test/integration/sitemap/origins_test.rb
require "test_helper"

class Sitemap::OriginsTest < ActionDispatch::IntegrationTest
  setup { sign_in_as(User.take) }

  def target!(host:, port: 443, scheme: "https", removed_at: nil)
    now = Time.current
    Sitemap::Target.create!(origin: "#{scheme}://#{host}:#{port}", scheme: scheme, host: host,
                            port: port, first_seen_at: now, last_seen_at: now, removed_at: removed_at)
  end

  def endpoint!(target, path)
    now = Time.current
    Sitemap::Endpoint.create!(target_id: target.id, origin: target.origin, url: "#{target.origin}#{path}",
      path: path, method: "GET", url_digest: Sitemap::Origin.digest("#{target.origin}#{path}", "GET"),
      first_seen_at: now, last_seen_at: now)
  end

  test "index lists active origins ordered by host with endpoint counts" do
    a = target!(host: "www.atg.se"); endpoint!(a, "/x"); endpoint!(a, "/y")
    target!(host: "iam.atg.se")
    target!(host: "gone.atg.se", removed_at: Time.current)

    get sitemap_root_path
    assert_response :success
    assert_select "[data-controller~=sitemap-tree]"
    assert_select "a[href=?]", sitemap_root_path # sidebar link present
    assert_match "iam.atg.se", @response.body
    assert_match "www.atg.se", @response.body
    assert_no_match "gone.atg.se", @response.body           # removed target hidden
    assert_select "[data-node] turbo-frame#origin_tree_#{a.id}[data-src=?]", sitemap_origin_tree_path(a)
  end

  test "q filters origins by host" do
    target!(host: "www.atg.se")
    target!(host: "presse.generali.fr")
    get sitemap_root_path(q: "generali")
    assert_match "presse.generali.fr", @response.body
    assert_no_match "www.atg.se", @response.body
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bin/rails test test/integration/sitemap/origins_test.rb`
Expected: FAIL — no route / uninitialized `Sitemap::OriginsController`.

- [ ] **Step 3: Add the routes**

In `web/config/routes.rb`, add a sibling department block next to the `namespace :cves` block (web departments, not under `namespace :api`):

```ruby
  namespace :sitemap do
    get "/",                 to: "origins#index", as: :root
    get "/origins/:id/tree", to: "origins#tree",  as: :origin_tree
    get "/endpoints/:id",    to: "endpoints#show", as: :endpoint
  end
```

- [ ] **Step 4: Write the controllers**

```ruby
# web/app/controllers/sitemap/base_controller.rb
module Sitemap
  # Base for every controller in the Sitemap web department.
  class BaseController < ApplicationController
    include Department

    TABS = [
      { name: "Sitemap", path: :sitemap_root_path }
    ].freeze
  end
end
```

```ruby
# web/app/controllers/sitemap/origins_controller.rb
module Sitemap
  # The sitemap department: a tree of target origins, each expandable into its
  # crawled-endpoint path tree. #index renders the origin list (top-level
  # folders); #tree lazily renders one origin's full path tree (Task 3).
  class OriginsController < BaseController
    def index
      @q = params[:q].to_s.strip
      scope = Sitemap::Target.active.order(:host, :port)
      if @q.present?
        scope = scope.where("host ILIKE ?", "%#{Sitemap::Target.sanitize_sql_like(@q)}%")
      end
      @targets = scope.to_a
      @counts = Sitemap::Endpoint.active.where(target_id: @targets.map(&:id)).group(:target_id).count
    end
  end
end
```

- [ ] **Step 5: Write the index + origin views**

```erb
<%# web/app/views/sitemap/origins/index.html.erb %>
<% content_for :title, "hunter — Sitemap" %>
<% content_for :container, "w-full" %>

<div class="flex h-[calc(100dvh-3rem)] w-full">
  <div class="flex w-full max-w-md shrink-0 flex-col border-r border-zinc-200 dark:border-zinc-800">
    <form action="<%= sitemap_root_path %>" method="get" class="border-b border-zinc-200 p-2 dark:border-zinc-800">
      <input type="search" name="q" value="<%= @q %>" placeholder="Search domain…"
             class="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm text-zinc-900 dark:border-zinc-700 dark:bg-[#111315] dark:text-zinc-100" />
    </form>

    <div data-controller="sitemap-tree" class="min-h-0 flex-1 overflow-y-auto slim-scroll py-1 text-sm">
      <ul>
        <%= render partial: "sitemap/origins/origin", collection: @targets, as: :target, locals: { counts: @counts } %>
      </ul>
      <% if @targets.empty? %>
        <p class="px-3 py-4 text-zinc-500 dark:text-zinc-400">No origins yet.</p>
      <% end %>
    </div>
  </div>

  <div class="min-w-0 flex-1">
    <%= turbo_frame_tag "sitemap_detail" do %>
      <p class="p-6 text-sm text-zinc-500 dark:text-zinc-400">Select an endpoint to see its detail.</p>
    <% end %>
  </div>
</div>
```

```erb
<%# web/app/views/sitemap/origins/_origin.html.erb %>
<li data-node>
  <button type="button" data-action="click->sitemap-tree#activate"
          class="flex w-full items-center gap-1.5 px-2 py-1 text-left hover:bg-zinc-100 dark:hover:bg-zinc-800">
    <span data-chevron class="inline-block w-3 shrink-0 text-zinc-400 transition-transform">▸</span>
    <span class="shrink-0 text-zinc-400"><%= target.scheme == "https" ? "🔒" : "🌐" %></span>
    <span class="truncate font-medium text-zinc-800 dark:text-zinc-100"><%= target.host %>:<%= target.port %></span>
    <span class="ml-auto shrink-0 rounded bg-zinc-200 px-1.5 text-xs text-zinc-600 dark:bg-zinc-700 dark:text-zinc-300"><%= counts[target.id].to_i %></span>
  </button>
  <div data-children hidden class="pl-4">
    <%= turbo_frame_tag "origin_tree_#{target.id}", data: { src: sitemap_origin_tree_path(target) } %>
  </div>
</li>
```

- [ ] **Step 6: Add the sidebar entry + icon**

In `web/app/helpers/navigation_helper.rb`, add to the module group in `primary_nav_groups` (after the "Target" entry):

```ruby
        { label: "Sitemap", path: sitemap_root_path, controllers: %w[sitemap], icon: "sitemap" },
```

In `web/app/helpers/icon_helper.rb`, add an entry to the `HEROICON_PATHS` hash (Heroicons v2 outline `rectangle-group`):

```ruby
    "sitemap" => [
      "M2.25 7.125C2.25 6.504 2.754 6 3.375 6h6c.621 0 1.125.504 1.125 1.125v3.75c0 .621-.504 1.125-1.125 1.125h-6a1.125 1.125 0 01-1.125-1.125v-3.75zM14.25 8.625c0-.621.504-1.125 1.125-1.125h5.25c.621 0 1.125.504 1.125 1.125v8.25c0 .621-.504 1.125-1.125 1.125h-5.25a1.125 1.125 0 01-1.125-1.125v-8.25zM3.75 16.125c0-.621.504-1.125 1.125-1.125h5.25c.621 0 1.125.504 1.125 1.125v2.25c0 .621-.504 1.125-1.125 1.125h-5.25a1.125 1.125 0 01-1.125-1.125v-2.25z"
    ],
```

- [ ] **Step 7: Run test to verify it passes**

Run: `cd web && bin/rails test test/integration/sitemap/origins_test.rb`
Expected: PASS (2 tests).

- [ ] **Step 8: Commit (scoped)**

`git add` only the files this task created/owns. `routes.rb` change is this task's; add it. For `navigation_helper.rb` / `icon_helper.rb`, these already carry unrelated uncommitted edits — do NOT `git add` them into this commit; leave them modified in the working tree and note it in the report (the sidebar entry + icon stay uncommitted alongside the existing Target/CVE nav edits).

```bash
git add web/app/controllers/sitemap/base_controller.rb web/app/controllers/sitemap/origins_controller.rb \
  web/app/views/sitemap/origins/index.html.erb web/app/views/sitemap/origins/_origin.html.erb \
  web/config/routes.rb web/test/integration/sitemap/origins_test.rb
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Add Sitemap department shell with the origin list and routes"
```

---

### Task 3: Per-origin path tree (lazy load + client toggle)

**Files:**
- Modify: `web/app/controllers/sitemap/origins_controller.rb` (add `#tree`)
- Create: `web/app/views/sitemap/origins/tree.html.erb`
- Create: `web/app/views/sitemap/origins/_node.html.erb`
- Create: `web/app/javascript/controllers/sitemap_tree_controller.js`
- Test: `web/test/integration/sitemap/tree_test.rb`

**Interfaces:**
- Consumes: `Sitemap::Tree.build`, `Sitemap::Target` (`.active`, `endpoints`), `Sitemap::Endpoint` (`.active`), `sitemap_endpoint_path`.
- Produces: `Sitemap::OriginsController#tree` renders the `origin_tree_<id>` Turbo Frame with the nested tree (or empty state). `_node` recursively renders folder rows (`data-action=click->sitemap-tree#activate`, with `[data-children]`) and leaf rows (with `data-url`). `sitemap_tree_controller#activate` toggles folders, lazy-loads the origin frame on first expand, and (for `data-url` rows) is extended in Task 4.

- [ ] **Step 1: Write the failing test**

```ruby
# web/test/integration/sitemap/tree_test.rb
require "test_helper"

class Sitemap::TreeFragmentTest < ActionDispatch::IntegrationTest
  setup { sign_in_as(User.take) }

  def target!(host: "www.atg.se")
    now = Time.current
    Sitemap::Target.create!(origin: "https://#{host}:443", scheme: "https", host: host, port: 443,
                            first_seen_at: now, last_seen_at: now)
  end

  def endpoint!(target, path)
    now = Time.current
    Sitemap::Endpoint.create!(target_id: target.id, origin: target.origin, url: "#{target.origin}#{path}",
      path: path, method: "GET", url_digest: Sitemap::Origin.digest("#{target.origin}#{path}", "GET"),
      first_seen_at: now, last_seen_at: now)
  end

  test "tree renders nested folders and leaf endpoints" do
    t = target!
    endpoint!(t, "/about")
    leaf = endpoint!(t, "/_nuxt/app.js")

    get sitemap_origin_tree_path(t)
    assert_response :success
    assert_select "turbo-frame#origin_tree_#{t.id}"
    assert_match "_nuxt/", @response.body                 # folder row
    assert_match "app.js", @response.body                 # leaf row
    assert_select "button[data-url=?]", sitemap_endpoint_path(leaf.id)   # leaf loads detail
    assert_select "button[data-action*='sitemap-tree#activate']"
  end

  test "empty state when the origin has no active endpoints" do
    t = target!
    get sitemap_origin_tree_path(t)
    assert_response :success
    assert_match(/no endpoints/i, @response.body)
  end

  test "tombstoned endpoints are excluded" do
    t = target!
    e = endpoint!(t, "/gone"); e.update!(removed_at: Time.current)
    get sitemap_origin_tree_path(t)
    assert_no_match "gone", @response.body
  end

  test "missing target is 404" do
    get sitemap_origin_tree_path(id: 999_999)
    assert_response :not_found
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bin/rails test test/integration/sitemap/tree_test.rb`
Expected: FAIL — no `tree` action / missing views.

- [ ] **Step 3: Add the `#tree` action**

Add to `web/app/controllers/sitemap/origins_controller.rb`:

```ruby
    def tree
      @target = Sitemap::Target.active.find_by(id: params[:id])
      return head :not_found unless @target

      @nodes = Sitemap::Tree.build(@target.endpoints.active)
      render :tree
    end
```

- [ ] **Step 4: Write the tree + node views**

```erb
<%# web/app/views/sitemap/origins/tree.html.erb %>
<%= turbo_frame_tag "origin_tree_#{@target.id}" do %>
  <% if @nodes.any? %>
    <ul>
      <%= render partial: "sitemap/origins/node", collection: @nodes, as: :node %>
    </ul>
  <% else %>
    <p class="px-2 py-1 text-zinc-500 dark:text-zinc-400">No endpoints.</p>
  <% end %>
<% end %>
```

```erb
<%# web/app/views/sitemap/origins/_node.html.erb %>
<li data-node>
  <button type="button" data-action="click->sitemap-tree#activate"
          <%= "data-url=#{sitemap_endpoint_path(node.endpoint.id)}".html_safe if node.endpoint? %>
          class="flex w-full items-center gap-1.5 px-2 py-1 text-left hover:bg-zinc-100 dark:hover:bg-zinc-800">
    <% if node.folder? %>
      <span data-chevron class="inline-block w-3 shrink-0 text-zinc-400 transition-transform">▸</span>
      <span class="shrink-0 text-zinc-400">📁</span>
    <% else %>
      <span class="inline-block w-3 shrink-0"></span>
      <span class="shrink-0 text-zinc-400">📄</span>
    <% end %>
    <span class="truncate text-zinc-700 dark:text-zinc-200"><%= node.label %></span>
  </button>
  <% if node.folder? %>
    <div data-children hidden class="pl-4">
      <ul><%= render partial: "sitemap/origins/node", collection: node.children, as: :node %></ul>
    </div>
  <% end %>
</li>
```

- [ ] **Step 5: Write the Stimulus controller**

```javascript
// web/app/javascript/controllers/sitemap_tree_controller.js
import { Controller } from "@hotwired/stimulus"

// Owns all sitemap-tree interactivity: expand/collapse folders, lazy-load an
// origin's tree Turbo Frame on first expand, and (Task 4) load endpoint detail.
export default class extends Controller {
  activate(event) {
    const row = event.currentTarget
    const li = row.closest("[data-node]")
    const children = li.querySelector(":scope > [data-children]")

    if (children) {
      const open = children.hidden
      children.hidden = !open
      const chevron = row.querySelector("[data-chevron]")
      if (chevron) chevron.classList.toggle("rotate-90", open)

      // Lazy-load an origin's tree frame the first time it opens.
      const frame = children.querySelector(":scope > turbo-frame[data-src]")
      if (open && frame && !frame.getAttribute("src")) {
        frame.setAttribute("src", frame.getAttribute("data-src"))
      }
    }
  }
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `cd web && bin/rails test test/integration/sitemap/tree_test.rb`
Expected: PASS (4 tests).

- [ ] **Step 7: Commit**

```bash
git add web/app/controllers/sitemap/origins_controller.rb web/app/views/sitemap/origins/tree.html.erb \
  web/app/views/sitemap/origins/_node.html.erb web/app/javascript/controllers/sitemap_tree_controller.js \
  web/test/integration/sitemap/tree_test.rb
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Render the per-origin sitemap path tree with lazy load and client toggle"
```

---

### Task 4: Endpoint detail panel + selection

**Files:**
- Create: `web/app/controllers/sitemap/endpoints_controller.rb`
- Create: `web/app/views/sitemap/endpoints/show.html.erb`
- Modify: `web/app/javascript/controllers/sitemap_tree_controller.js` (endpoint selection)
- Test: `web/test/integration/sitemap/endpoints_test.rb`

**Interfaces:**
- Consumes: `Sitemap::Endpoint` (`.active`, `url/method/status_code/last_seen_at`), the `sitemap_detail` Turbo Frame from Task 2's index.
- Produces: `Sitemap::EndpointsController#show` renders the `sitemap_detail` frame with the endpoint's method, an inline status pill, full URL, and last-seen. `sitemap_tree_controller#activate` additionally loads `row.dataset.url` into the `sitemap_detail` frame and marks the row selected.

- [ ] **Step 1: Write the failing test**

```ruby
# web/test/integration/sitemap/endpoints_test.rb
require "test_helper"

class Sitemap::EndpointsTest < ActionDispatch::IntegrationTest
  setup { sign_in_as(User.take) }

  def endpoint!(path: "/about", status: 200, removed_at: nil)
    now = Time.current
    t = Sitemap::Target.create!(origin: "https://ex.com:443", scheme: "https", host: "ex.com", port: 443,
                                first_seen_at: now, last_seen_at: now)
    Sitemap::Endpoint.create!(target_id: t.id, origin: t.origin, url: "#{t.origin}#{path}", path: path,
      method: "GET", status_code: status, url_digest: Sitemap::Origin.digest("#{t.origin}#{path}", "GET"),
      first_seen_at: now, last_seen_at: now, removed_at: removed_at)
  end

  test "shows method, status, url and last-seen in the detail frame" do
    e = endpoint!(path: "/about", status: 200)
    get sitemap_endpoint_path(e.id)
    assert_response :success
    assert_select "turbo-frame#sitemap_detail"
    assert_match "GET", @response.body
    assert_match "200", @response.body
    assert_match "https://ex.com:443/about", @response.body
  end

  test "missing endpoint is 404" do
    get sitemap_endpoint_path(id: 999_999)
    assert_response :not_found
  end

  test "tombstoned endpoint is 404" do
    e = endpoint!(removed_at: Time.current)
    get sitemap_endpoint_path(e.id)
    assert_response :not_found
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bin/rails test test/integration/sitemap/endpoints_test.rb`
Expected: FAIL — uninitialized `Sitemap::EndpointsController`.

- [ ] **Step 3: Write the controller**

```ruby
# web/app/controllers/sitemap/endpoints_controller.rb
module Sitemap
  # Renders one endpoint's detail into the shared `sitemap_detail` Turbo Frame.
  class EndpointsController < BaseController
    def show
      @endpoint = Sitemap::Endpoint.active.find_by(id: params[:id])
      return head :not_found unless @endpoint

      render :show
    end
  end
end
```

- [ ] **Step 4: Write the detail view (inline status pill)**

```erb
<%# web/app/views/sitemap/endpoints/show.html.erb %>
<%= turbo_frame_tag "sitemap_detail" do %>
  <% family = @endpoint.status_code.to_i / 100 %>
  <% pill = { 2 => "bg-emerald-100 text-emerald-800 dark:bg-emerald-900/40 dark:text-emerald-300",
              3 => "bg-sky-100 text-sky-800 dark:bg-sky-900/40 dark:text-sky-300",
              4 => "bg-amber-100 text-amber-800 dark:bg-amber-900/40 dark:text-amber-300",
              5 => "bg-red-100 text-red-800 dark:bg-red-900/40 dark:text-red-300" }[family] ||
             "bg-zinc-200 text-zinc-700 dark:bg-zinc-700 dark:text-zinc-300" %>
  <div class="space-y-4 p-6">
    <div class="flex items-center gap-2">
      <span class="rounded border border-zinc-300 px-1.5 py-0.5 text-xs font-semibold text-zinc-700 dark:border-zinc-700 dark:text-zinc-200"><%= @endpoint.method %></span>
      <% if @endpoint.status_code.present? %>
        <span class="rounded px-1.5 py-0.5 text-xs font-semibold <%= pill %>"><%= @endpoint.status_code %></span>
      <% end %>
    </div>
    <div>
      <div class="text-xs uppercase tracking-wide text-zinc-400">URL</div>
      <div class="break-all font-mono text-sm text-zinc-800 dark:text-zinc-100"><%= @endpoint.url %></div>
    </div>
    <div>
      <div class="text-xs uppercase tracking-wide text-zinc-400">Last seen</div>
      <div class="text-sm text-zinc-700 dark:text-zinc-200"><%= time_ago_in_words(@endpoint.last_seen_at) %> ago</div>
    </div>
  </div>
<% end %>
```

- [ ] **Step 5: Extend the Stimulus controller for selection**

Replace the body of `activate` in `web/app/javascript/controllers/sitemap_tree_controller.js` so it also loads endpoint detail:

```javascript
// web/app/javascript/controllers/sitemap_tree_controller.js
import { Controller } from "@hotwired/stimulus"

// Owns all sitemap-tree interactivity: expand/collapse folders, lazy-load an
// origin's tree Turbo Frame on first expand, and load endpoint detail on click.
export default class extends Controller {
  activate(event) {
    const row = event.currentTarget
    const li = row.closest("[data-node]")
    const children = li.querySelector(":scope > [data-children]")

    if (children) {
      const open = children.hidden
      children.hidden = !open
      const chevron = row.querySelector("[data-chevron]")
      if (chevron) chevron.classList.toggle("rotate-90", open)

      const frame = children.querySelector(":scope > turbo-frame[data-src]")
      if (open && frame && !frame.getAttribute("src")) {
        frame.setAttribute("src", frame.getAttribute("data-src"))
      }
    }

    const url = row.dataset.url
    if (url) {
      const detail = document.getElementById("sitemap_detail")
      if (detail) detail.setAttribute("src", url)
      this.element.querySelectorAll("[data-selected]").forEach((el) => delete el.dataset.selected)
      row.dataset.selected = "true"
    }
  }
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `cd web && bin/rails test test/integration/sitemap/endpoints_test.rb`
Expected: PASS (3 tests).

- [ ] **Step 7: Commit**

```bash
git add web/app/controllers/sitemap/endpoints_controller.rb web/app/views/sitemap/endpoints/show.html.erb \
  web/app/javascript/controllers/sitemap_tree_controller.js web/test/integration/sitemap/endpoints_test.rb
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Add the sitemap endpoint detail panel and tree selection"
```

---

## Final verification

- [ ] **Run the full sitemap department suite**

Run: `cd web && bin/rails test test/services/sitemap/tree_test.rb test/integration/sitemap/`
Expected: all green.

- [ ] **Run the whole suite (excluding the known-broken pre-existing file) to confirm no regressions**

Run: `cd web && bin/rails test $(find test -name '*_test.rb' ! -path 'test/integration/api/runner/jobs_test.rb')`
Expected: green (only any documented pre-existing baseline failures, if present, remain).

- [ ] **Live smoke (stack up, run by the user):** visit `/sitemap`, expand an origin (tree lazy-loads), drill folders, click a leaf (detail panel fills), and use the domain search box.
