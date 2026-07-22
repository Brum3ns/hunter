# Hunter Sitemap — Tree Redesign + Filters Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign the sitemap tree (elbow connectors, SVG icons, non-GET method chips, red parameterized labels) and add a robust filter panel (method, min endpoint count, status family, path-contains, has-parameter, content-type, program, scheme).

**Architecture:** `Sitemap::Tree` aggregates per-node `methods` + `has_query`. A shared `Sitemap::EndpointFilter` turns filter params into one endpoint scope used by both `#index` (filtered counts + min-count visibility) and `#tree` (filter before building). Elbow connectors are pure CSS; icons are heroicons. Filters submit via GET and thread the endpoint-level params into each origin's lazy tree frame.

**Tech Stack:** Ruby 3.3.6, Rails 8, Tailwind v4 (`app/assets/tailwind/application.css`), importmap + Stimulus/Turbo, Minitest. Postgres-only.

## Global Constraints

- Read-only over existing `sitemap_targets` / `sitemap_endpoints`. **No schema changes.** Active rows only (`.active`).
- Namespace `Sitemap::`. Web 404 = `head :not_found`.
- Self-contained: no dependency on the uncommitted Targets module. All emojis removed; icons via `IconHelper` heroicons.
- Color is information-bearing only: red parameterized label, per-method chip tone, status pill. Everything else neutral zinc.
- "Has parameter" = endpoint `url` contains `?`. Status families: 2xx=200..299, 3xx=300..399, 4xx=400..499, 5xx=500..599; null status excluded when a status filter is active.
- Min endpoint count default = 1 (0-endpoint origins hidden); an explicit `min_count=0` shows all.
- Commit author `Claude <noreply@anthropic.com>`; single-sentence messages. `# web/...` header lines in code blocks are FILE LOCATORS, not source.
- **`icon_helper.rb` is already tracked-but-uncommitted** (carries prior Target/CVE/sitemap edits) — add icons to it but do NOT commit it; leave it uncommitted and note so. Commit only the other files each task owns. `app/assets/tailwind/application.css` is clean → commit it normally.
- Tests run from `web/` with `bin/rails test`; Postgres reachable, Mongo not needed (ignore `MONGODB ... Connection refused`).

---

### Task 1: `Sitemap::Tree` — aggregate `methods` + `has_query`

**Files:**
- Modify: `web/app/services/sitemap/tree.rb`
- Test: `web/test/services/sitemap/tree_test.rb`

**Interfaces:**
- Produces: `Sitemap::Tree::Node` = `Struct(:label, :full_path, :endpoint, :children, :methods, :has_query)` with `folder?`, `endpoint?`, and `has_query?` (returns the `has_query` field). `methods` is a sorted unique `Array<String>` of upcased HTTP methods for every endpoint terminating at the node (`[]` for pure folders). Endpoints must respond to `#url` in addition to `#id/#path/#method/#status_code`.

- [ ] **Step 1: Add failing tests** (append to `web/test/services/sitemap/tree_test.rb`; also update the `Ep` struct to include `:url`)

Replace the `Ep` definition at the top of the test class with:
```ruby
  Ep = Struct.new(:id, :path, :method, :status_code, :url)

  def build(*paths)
    eps = paths.each_with_index.map { |p, i| Ep.new(i + 1, p, "GET", 200, "https://ex.com:443#{p}") }
    Sitemap::Tree.build(eps)
  end
```

Append these tests:
```ruby
  test "methods aggregates unique upcased methods at a node" do
    eps = [Ep.new(1, "/x", "get", 200, "https://ex.com/x"),
           Ep.new(2, "/x", "post", 201, "https://ex.com/x")]
    node = Sitemap::Tree.build(eps).sole
    assert_equal ["GET", "POST"], node.methods
  end

  test "has_query? is true when any endpoint at the node has a query string" do
    eps = [Ep.new(1, "/s", "GET", 200, "https://ex.com/s"),
           Ep.new(2, "/s", "GET", 200, "https://ex.com/s?a=1")]
    node = Sitemap::Tree.build(eps).sole
    assert node.has_query?
  end

  test "has_query? false and methods present for a plain endpoint" do
    node = build("/plain").sole
    refute node.has_query?
    assert_equal ["GET"], node.methods
  end

  test "pure folder node has empty methods and no query" do
    folder = build("/dir/child").sole
    assert_equal "dir/", folder.label
    assert_equal [], folder.methods
    refute folder.has_query?
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd web && bin/rails test test/services/sitemap/tree_test.rb`
Expected: FAIL — `Node` has no `methods`/`has_query`.

- [ ] **Step 3: Update the implementation**

In `web/app/services/sitemap/tree.rb`, change the `Node` struct and the `entry`/`insert`/`to_nodes` methods:

```ruby
    Node = Struct.new(:label, :full_path, :endpoint, :children, :methods, :has_query, keyword_init: true) do
      def folder?    = children.any?
      def endpoint?  = !endpoint.nil?
      def has_query? = has_query
    end
```

In `entry`, add the two accumulators:
```ruby
    def entry(label, full) = { label: label, full_path: full, endpoint: nil, children: {}, methods: [], has_query: false }
    private_class_method :entry
```

In `insert`, when an endpoint terminates at a node, accumulate onto that node. Both the `parts.empty?` root branch and the `if last` branch must do it. Extract a helper and call it at both terminal points:
```ruby
    def insert(root, endpoint)
      path = endpoint.path.to_s
      path = "/#{path}" unless path.start_with?("/")
      parts = path.sub(%r{\A/}, "").split("/").reject(&:empty?)

      if parts.empty? # the "/" root request
        terminate(root["/"] ||= entry("/", "/"), endpoint)
        return
      end

      dir = path.end_with?("/")
      level = root
      path_parts = []
      parts.each_with_index do |part, i|
        last = i == parts.length - 1
        is_dir = last ? dir : true
        label = is_dir ? "#{part}/" : part
        path_parts << part
        full = "/" + path_parts.join("/") + (is_dir ? "/" : "")
        e = (level[label] ||= entry(label, full))
        terminate(e, endpoint) if last
        level = e[:children]
      end
    end
    private_class_method :insert

    def terminate(node_entry, endpoint)
      node_entry[:endpoint] ||= endpoint
      node_entry[:methods] |= [endpoint.method.to_s.upcase]
      node_entry[:has_query] ||= endpoint.url.to_s.include?("?")
    end
    private_class_method :terminate
```

In `to_nodes`, carry the two fields through (sort methods):
```ruby
    def to_nodes(level)
      nodes = level.values.map do |e|
        Node.new(label: e[:label], full_path: e[:full_path], endpoint: e[:endpoint],
                 children: to_nodes(e[:children]), methods: e[:methods].sort, has_query: e[:has_query])
      end
      nodes.sort_by { |n| [n.folder? ? 0 : 1, n.label.downcase] }
    end
    private_class_method :to_nodes
```

(Keep the `path_parts` accumulator — it fixed the earlier double-slash bug.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd web && bin/rails test test/services/sitemap/tree_test.rb`
Expected: PASS (existing 8 + 4 new = 12).

- [ ] **Step 5: Commit**

```bash
git add web/app/services/sitemap/tree.rb web/test/services/sitemap/tree_test.rb
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Aggregate methods and has_query onto Sitemap::Tree nodes"
```

---

### Task 2: `Sitemap::EndpointFilter` service

**Files:**
- Create: `web/app/services/sitemap/endpoint_filter.rb`
- Test: `web/test/services/sitemap/endpoint_filter_test.rb`

**Interfaces:**
- Produces: `Sitemap::EndpointFilter.apply(scope, params) -> ActiveRecord::Relation`. `scope` is a `Sitemap::Endpoint` relation; `params` is a hash/ActionController::Params with any of `methods` (array), `status` (array of `"2".."5"`), `path` (string), `has_query` (truthy), `content_type` (string). Blank/unknown ignored; filters AND together.

- [ ] **Step 1: Write the failing test**

```ruby
# web/test/services/sitemap/endpoint_filter_test.rb
require "test_helper"

class Sitemap::EndpointFilterTest < ActiveSupport::TestCase
  def target
    @target ||= begin
      now = Time.current
      Sitemap::Target.create!(origin: "https://ex.com:443", scheme: "https", host: "ex.com", port: 443,
                              first_seen_at: now, last_seen_at: now)
    end
  end

  def ep!(path:, method: "GET", status: 200, url: nil, content_type: nil)
    now = Time.current
    url ||= "https://ex.com:443#{path}"
    Sitemap::Endpoint.create!(target_id: target.id, origin: target.origin, url: url, path: path,
      method: method, status_code: status, content_type: content_type,
      url_digest: Sitemap::Origin.digest(url, method), first_seen_at: now, last_seen_at: now)
  end

  def apply(params) = Sitemap::EndpointFilter.apply(Sitemap::Endpoint.active, params).to_a

  test "blank params return the scope unfiltered" do
    a = ep!(path: "/a")
    assert_includes apply({}), a
  end

  test "methods filter (upcased)" do
    g = ep!(path: "/g", method: "GET"); p = ep!(path: "/p", method: "POST")
    result = apply(methods: ["post"])
    assert_includes result, p
    assert_not_includes result, g
  end

  test "status family filter excludes null and out-of-range" do
    ok = ep!(path: "/ok", status: 200); notf = ep!(path: "/nf", status: 404); nul = ep!(path: "/n", status: nil)
    result = apply(status: ["2"])
    assert_includes result, ok
    assert_not_includes result, notf
    assert_not_includes result, nul
  end

  test "path substring filter" do
    admin = ep!(path: "/admin/x"); other = ep!(path: "/public")
    result = apply(path: "admin")
    assert_includes result, admin
    assert_not_includes result, other
  end

  test "has_query filter matches urls with a query string" do
    q = ep!(path: "/s", url: "https://ex.com:443/s?a=1"); plain = ep!(path: "/t")
    result = apply(has_query: "1")
    assert_includes result, q
    assert_not_includes result, plain
  end

  test "content_type filter" do
    js = ep!(path: "/a.js", content_type: "application/javascript"); html = ep!(path: "/b", content_type: "text/html")
    result = apply(content_type: "javascript")
    assert_includes result, js
    assert_not_includes result, html
  end

  test "filters compose" do
    hit = ep!(path: "/api/x", method: "POST", status: 200)
    miss = ep!(path: "/api/y", method: "GET", status: 200)
    result = apply(methods: ["POST"], status: ["2"], path: "api")
    assert_equal [hit], result
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bin/rails test test/services/sitemap/endpoint_filter_test.rb`
Expected: FAIL — constant undefined.

- [ ] **Step 3: Write the implementation**

```ruby
# web/app/services/sitemap/endpoint_filter.rb
module Sitemap
  # Turns filter params into a single endpoint scope, shared by the origin-count
  # query (#index) and the per-origin tree build (#tree) so both apply identical
  # endpoint criteria. Target-level filters (program/scheme/host) are applied on
  # the Target scope by the controller, not here.
  module EndpointFilter
    module_function

    STATUS_RANGES = { "2" => 200..299, "3" => 300..399, "4" => 400..499, "5" => 500..599 }.freeze
    TRUTHY = %w[1 true on yes].freeze

    def apply(scope, params)
      params ||= {}
      scope = by_methods(scope, params[:methods])
      scope = by_status(scope, params[:status])
      scope = by_path(scope, params[:path])
      scope = by_has_query(scope, params[:has_query])
      scope = by_content_type(scope, params[:content_type])
      scope
    end

    def by_methods(scope, methods)
      list = Array(methods).map { |m| m.to_s.strip.upcase }.reject(&:empty?)
      list.empty? ? scope : scope.where(method: list)
    end
    private_class_method :by_methods

    def by_status(scope, families)
      fams = Array(families).map(&:to_s).select { |f| STATUS_RANGES.key?(f) }
      return scope if fams.empty?
      fams.map { |f| scope.where(status_code: STATUS_RANGES[f]) }.reduce(:or)
    end
    private_class_method :by_status

    def by_path(scope, path)
      return scope if path.to_s.strip.empty?
      scope.where("path ILIKE ?", "%#{Sitemap::Endpoint.sanitize_sql_like(path.to_s.strip)}%")
    end
    private_class_method :by_path

    def by_has_query(scope, flag)
      TRUTHY.include?(flag.to_s.downcase) ? scope.where("url LIKE ?", "%?%") : scope
    end
    private_class_method :by_has_query

    def by_content_type(scope, ctype)
      return scope if ctype.to_s.strip.empty?
      scope.where("content_type ILIKE ?", "%#{Sitemap::Endpoint.sanitize_sql_like(ctype.to_s.strip)}%")
    end
    private_class_method :by_content_type
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bin/rails test test/services/sitemap/endpoint_filter_test.rb`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add web/app/services/sitemap/endpoint_filter.rb web/test/services/sitemap/endpoint_filter_test.rb
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Add Sitemap::EndpointFilter for shared endpoint filtering"
```

---

### Task 3: Controller filters — `#index` counts/visibility + `#tree`

**Files:**
- Modify: `web/app/controllers/sitemap/origins_controller.rb`
- Test: `web/test/integration/sitemap/origins_test.rb` (extend)

**Interfaces:**
- Consumes: `Sitemap::EndpointFilter.apply`.
- Produces: `#index` assigns `@targets` (active, host/program/scheme-filtered, kept only when filtered endpoint count `>= @min_count`), `@counts`, `@min_count`, `@programs`, `@method_options`, and `@filter` (the endpoint-filter params hash, for the panel + frame `data-src`). `#tree` builds `@nodes` from the filtered endpoint scope. Private `endpoint_filter_params` returns the permitted endpoint params.

- [ ] **Step 1: Write the failing tests** (append to `web/test/integration/sitemap/origins_test.rb`; the file already has `target!`/`endpoint!` helpers — reuse them, adding a `method:`/`status:` option if missing)

Ensure the `endpoint!` helper accepts method/status (update it if needed):
```ruby
  def endpoint!(target, path, method: "GET", status: 200)
    now = Time.current
    Sitemap::Endpoint.create!(target_id: target.id, origin: target.origin, url: "#{target.origin}#{path}",
      path: path, method: method, status_code: status,
      url_digest: Sitemap::Origin.digest("#{target.origin}#{path}", method),
      first_seen_at: now, last_seen_at: now)
  end
```

Append:
```ruby
  test "default hides origins with zero endpoints" do
    a = target!(host: "has.ep"); endpoint!(a, "/x")
    target!(host: "no.ep")
    get sitemap_root_path
    assert_match "has.ep", @response.body
    assert_no_match "no.ep", @response.body
  end

  test "min_count hides origins below the threshold" do
    a = target!(host: "one.ep"); endpoint!(a, "/x")
    b = target!(host: "three.ep"); endpoint!(b, "/a"); endpoint!(b, "/b"); endpoint!(b, "/c")
    get sitemap_root_path(min_count: 2)
    assert_match "three.ep", @response.body
    assert_no_match "one.ep", @response.body
  end

  test "method filter changes which origins qualify" do
    a = target!(host: "posts.only"); endpoint!(a, "/x", method: "POST")
    b = target!(host: "gets.only"); endpoint!(b, "/y", method: "GET")
    get sitemap_root_path(methods: ["POST"])
    assert_match "posts.only", @response.body
    assert_no_match "gets.only", @response.body
  end

  test "program filter restricts the origin list" do
    a = target!(host: "atg.host"); a.update!(program: "atg"); endpoint!(a, "/x")
    b = target!(host: "gen.host"); b.update!(program: "gen"); endpoint!(b, "/y")
    get sitemap_root_path(program: "atg")
    assert_match "atg.host", @response.body
    assert_no_match "gen.host", @response.body
  end

  test "tree applies the method filter to the built nodes" do
    t = target!(host: "t.host"); endpoint!(t, "/keep", method: "POST"); endpoint!(t, "/drop", method: "GET")
    get sitemap_origin_tree_path(t, methods: ["POST"])
    assert_response :success
    assert_match "keep", @response.body
    assert_no_match "drop", @response.body
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd web && bin/rails test test/integration/sitemap/origins_test.rb`
Expected: FAIL — no filtering yet (0-endpoint origin shows, method filter ignored, etc.).

- [ ] **Step 3: Rewrite the controller**

```ruby
# web/app/controllers/sitemap/origins_controller.rb
module Sitemap
  # The sitemap department: a tree of target origins, each expandable into its
  # crawled-endpoint path tree. Filters (method, status, path, has-query,
  # content-type via EndpointFilter; program/scheme/host + min-count here) apply
  # to both the origin list's counts/visibility and each origin's tree.
  class OriginsController < BaseController
    def index
      @q       = params[:q].to_s.strip
      @program = params[:program].presence
      @scheme  = params[:scheme].presence
      raw_min  = params[:min_count]
      @min_count = raw_min.present? ? [raw_min.to_i, 0].max : 1

      targets = Sitemap::Target.active.order(:host, :port)
      targets = targets.where("host ILIKE ?", "%#{Sitemap::Target.sanitize_sql_like(@q)}%") if @q.present?
      targets = targets.where(program: @program) if @program
      targets = targets.where(scheme: @scheme) if @scheme
      candidates = targets.to_a

      @counts = Sitemap::EndpointFilter.apply(Sitemap::Endpoint.active, endpoint_filter_params)
                                       .where(target_id: candidates.map(&:id))
                                       .group(:target_id).count
      @targets = candidates.select { |t| @counts[t.id].to_i >= @min_count }

      @programs       = Sitemap::Target.active.distinct.pluck(:program).compact.sort
      @method_options = Sitemap::Endpoint.active.distinct.pluck(:method).compact.sort
      @filter         = endpoint_filter_params.to_h
    end

    def tree
      @target = Sitemap::Target.active.find_by(id: params[:id])
      return head :not_found unless @target

      @nodes = Sitemap::Tree.build(Sitemap::EndpointFilter.apply(@target.endpoints.active, endpoint_filter_params))
      render :tree
    end

    private

    def endpoint_filter_params
      params.permit(:path, :has_query, :content_type, methods: [], status: [])
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd web && bin/rails test test/integration/sitemap/origins_test.rb`
Expected: PASS (existing + 5 new).

- [ ] **Step 5: Commit**

```bash
git add web/app/controllers/sitemap/origins_controller.rb web/test/integration/sitemap/origins_test.rb
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Apply sitemap filters to origin counts, visibility and the tree"
```

---

### Task 4: Tree visual redesign — elbow connectors, SVG icons, method chips, red params

**Files:**
- Modify: `web/app/views/sitemap/origins/_node.html.erb`
- Modify: `web/app/views/sitemap/origins/tree.html.erb`
- Modify: `web/app/views/sitemap/origins/_origin.html.erb`
- Modify: `web/app/assets/tailwind/application.css` (elbow-tree CSS)
- Modify: `web/app/helpers/icon_helper.rb` (add heroicon paths — **leave uncommitted**)
- Test: `web/test/integration/sitemap/tree_test.rb` (extend)

**Interfaces:**
- Consumes: `Sitemap::Tree::Node` `methods`/`has_query?` (Task 1), `@filter` (Task 3), `heroicon` helper.
- Produces: elbow-connector markup (`ul.sitemap-subtree`), SVG icons (no emoji), non-GET method chips, red parameterized labels, and `_origin` frame `data-src` carrying `@filter`.

- [ ] **Step 1: Add heroicon paths** (in `web/app/helpers/icon_helper.rb`, add these entries to `HEROICON_PATHS` — this file stays uncommitted)

```ruby
    "chevron-right" => [ "M8.25 4.5l7.5 7.5-7.5 7.5" ],
    "folder" => [ "M2.25 12.75V12A2.25 2.25 0 014.5 9.75h15A2.25 2.25 0 0121.75 12v.75m-8.69-6.44l-2.12-2.12a1.5 1.5 0 00-1.061-.44H4.5A2.25 2.25 0 002.25 6v12a2.25 2.25 0 002.25 2.25h15A2.25 2.25 0 0021.75 18V9a2.25 2.25 0 00-2.25-2.25h-5.379a1.5 1.5 0 01-1.06-.44z" ],
    "document" => [ "M19.5 14.25v-2.625a3.375 3.375 0 00-3.375-3.375h-1.5A1.125 1.125 0 0113.5 7.125v-1.5a3.375 3.375 0 00-3.375-3.375H8.25m2.25 0H5.625c-.621 0-1.125.504-1.125 1.125v17.25c0 .621.504 1.125 1.125 1.125h12.75c.621 0 1.125-.504 1.125-1.125V11.25a9 9 0 00-9-9z" ],
    "lock-closed" => [ "M16.5 10.5V6.75a4.5 4.5 0 10-9 0v3.75m-.75 11.25h10.5a2.25 2.25 0 002.25-2.25v-6.75a2.25 2.25 0 00-2.25-2.25H6.75a2.25 2.25 0 00-2.25 2.25v6.75a2.25 2.25 0 002.25 2.25z" ],
    "globe-alt" => [ "M12 21a9.004 9.004 0 008.716-6.747M12 21a9.004 9.004 0 01-8.716-6.747M12 21c2.485 0 4.5-4.03 4.5-9S14.485 3 12 3m0 18c-2.485 0-4.5-4.03-4.5-9S9.515 3 12 3m0 0a8.997 8.997 0 017.843 4.582M12 3a8.997 8.997 0 00-7.843 4.582m15.686 0A11.953 11.953 0 0112 10.5c-2.998 0-5.74-1.1-7.843-2.918m15.686 0A8.959 8.959 0 0121 12c0 .778-.099 1.533-.284 2.253m0 0A17.919 17.919 0 0112 16.5c-3.162 0-6.133-.815-8.716-2.247m0 0A9.015 9.015 0 013 12c0-1.605.42-3.113 1.157-4.418" ],
```

- [ ] **Step 2: Add the elbow-tree CSS** (append to `web/app/assets/tailwind/application.css`)

```css
@layer components {
  /* Sitemap tree: elbow connectors drawn purely in CSS so any depth works.
     Each nested list is a .sitemap-subtree; each row (li) draws a vertical
     guide plus a horizontal elbow, and the last child truncates the guide at
     the elbow to form the corner. */
  .sitemap-subtree { padding-left: 0.75rem; }
  .sitemap-subtree > li { position: relative; padding-left: 0.85rem; }
  .sitemap-subtree > li::before {
    content: ""; position: absolute; left: 0; top: 0; height: 100%;
    border-left: 1px solid rgb(212 212 216); /* zinc-300 */
  }
  .sitemap-subtree > li:last-child::before { height: 0.95rem; }
  .sitemap-subtree > li::after {
    content: ""; position: absolute; left: 0; top: 0.95rem; width: 0.6rem;
    border-top: 1px solid rgb(212 212 216);
  }
  .dark .sitemap-subtree > li::before,
  .dark .sitemap-subtree > li::after { border-color: rgb(255 255 255 / 0.12); }
}
```

- [ ] **Step 3: Write the failing test** (append to `web/test/integration/sitemap/tree_test.rb`)

```ruby
  test "tree uses SVG icons, elbow subtree, method chip on non-GET, red on query" do
    t = target!(host: "vis.host")
    endpoint!(t, "/nuxt/app.js")                     # nested -> folder + leaf
    endpoint!(t, "/submit", method: "POST")          # non-GET -> chip
    now = Time.current
    Sitemap::Endpoint.create!(target_id: t.id, origin: t.origin, url: "#{t.origin}/s?a=1", path: "/s",
      method: "GET", url_digest: Sitemap::Origin.digest("#{t.origin}/s?a=1", "GET"),
      first_seen_at: now, last_seen_at: now)         # parameterized -> red

    get sitemap_origin_tree_path(t)
    assert_response :success
    assert_select "ul.sitemap-subtree"                       # elbow container
    assert_select "svg", minimum: 1                          # SVG icons present
    assert_no_match(/📁|📄|▸/, @response.body)               # no emojis
    assert_match "POST", @response.body                      # non-GET method chip
    assert_select ".text-red-600, .text-red-500, .text-red-400" # parameterized label styled red
  end
```

- [ ] **Step 4: Run test to verify it fails**

Run: `cd web && bin/rails test test/integration/sitemap/tree_test.rb`
Expected: FAIL — emojis still present / no `sitemap-subtree` / no chip.

- [ ] **Step 5: Rewrite the tree + node + origin views**

```erb
<%# web/app/views/sitemap/origins/tree.html.erb %>
<%= turbo_frame_tag "origin_tree_#{@target.id}" do %>
  <% if @nodes.any? %>
    <ul class="sitemap-subtree">
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
          <%= 'aria-expanded="false"'.html_safe if node.folder? %>
          class="flex w-full items-center gap-1.5 px-2 py-1 text-left hover:bg-zinc-100 dark:hover:bg-zinc-800 data-[selected]:bg-zinc-200 dark:data-[selected]:bg-zinc-800">
    <% if node.folder? %>
      <span data-chevron class="inline-flex w-4 shrink-0 text-zinc-400 transition-transform"><%= heroicon "chevron-right", classes: "h-4 w-4" %></span>
      <span class="shrink-0 text-zinc-400"><%= heroicon "folder", classes: "h-4 w-4" %></span>
    <% else %>
      <span class="inline-block w-4 shrink-0"></span>
      <span class="shrink-0 text-zinc-400"><%= heroicon "document", classes: "h-4 w-4" %></span>
    <% end %>
    <span class="truncate <%= node.has_query? ? "text-red-600 dark:text-red-400" : "text-zinc-700 dark:text-zinc-200" %>"><%= node.label %></span>
    <% node.methods.reject { |m| m == "GET" }.each do |m| %>
      <span class="ml-1 shrink-0 rounded px-1 text-[10px] font-semibold <%= sitemap_method_class(m) %>"><%= m %></span>
    <% end %>
  </button>
  <% if node.folder? %>
    <div data-children hidden>
      <ul class="sitemap-subtree"><%= render partial: "sitemap/origins/node", collection: node.children, as: :node %></ul>
    </div>
  <% end %>
</li>
```

Add a helper for method-chip color. In `web/app/helpers/sitemap_helper.rb` (create it):
```ruby
# web/app/helpers/sitemap_helper.rb
module SitemapHelper
  METHOD_CLASSES = {
    "POST"   => "bg-amber-100 text-amber-800 dark:bg-amber-900/40 dark:text-amber-300",
    "PUT"    => "bg-sky-100 text-sky-800 dark:bg-sky-900/40 dark:text-sky-300",
    "PATCH"  => "bg-sky-100 text-sky-800 dark:bg-sky-900/40 dark:text-sky-300",
    "DELETE" => "bg-red-100 text-red-800 dark:bg-red-900/40 dark:text-red-300"
  }.freeze

  def sitemap_method_class(method)
    METHOD_CLASSES[method.to_s.upcase] || "bg-zinc-200 text-zinc-700 dark:bg-zinc-700 dark:text-zinc-300"
  end
end
```

```erb
<%# web/app/views/sitemap/origins/_origin.html.erb %>
<li data-node>
  <button type="button" data-action="click->sitemap-tree#activate" aria-expanded="false"
          class="flex w-full items-center gap-1.5 px-2 py-1 text-left hover:bg-zinc-100 dark:hover:bg-zinc-800">
    <span data-chevron class="inline-flex w-4 shrink-0 text-zinc-400 transition-transform"><%= heroicon "chevron-right", classes: "h-4 w-4" %></span>
    <span class="shrink-0 text-zinc-400"><%= heroicon(target.scheme == "https" ? "lock-closed" : "globe-alt", classes: "h-4 w-4") %></span>
    <span class="truncate font-medium text-zinc-800 dark:text-zinc-100"><%= target.host %>:<%= target.port %></span>
    <span class="ml-auto shrink-0 rounded bg-zinc-200 px-1.5 text-xs text-zinc-600 dark:bg-zinc-700 dark:text-zinc-300"><%= counts[target.id].to_i %></span>
  </button>
  <div data-children hidden>
    <%= turbo_frame_tag "origin_tree_#{target.id}", data: { src: sitemap_origin_tree_path(target, filter) } %>
  </div>
</li>
```

Note `_origin` now takes a `filter` local (the endpoint-filter params). Update the collection render in `index.html.erb` to pass it (Task 5 finalizes the index, but make the locals available now):
in `web/app/views/sitemap/origins/index.html.erb`, change the origin collection render to:
```erb
        <%= render partial: "sitemap/origins/origin", collection: @targets, as: :target, locals: { counts: @counts, filter: @filter } %>
```

- [ ] **Step 6: Run test to verify it passes**

Run: `cd web && bin/rails test test/integration/sitemap/tree_test.rb test/integration/sitemap/origins_test.rb`
Expected: PASS.

- [ ] **Step 7: Commit (scoped — icon_helper.rb stays uncommitted)**

```bash
git add web/app/views/sitemap/origins/_node.html.erb web/app/views/sitemap/origins/tree.html.erb \
  web/app/views/sitemap/origins/_origin.html.erb web/app/views/sitemap/origins/index.html.erb \
  web/app/helpers/sitemap_helper.rb web/app/assets/tailwind/application.css \
  web/test/integration/sitemap/tree_test.rb
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Redesign the sitemap tree with elbow connectors, SVG icons, method chips and red parameterized labels"
```

Then run `git status --porcelain web/app/helpers/icon_helper.rb` and confirm it is still ` M` (uncommitted); note this in the report.

---

### Task 5: Filter panel UI

**Files:**
- Create: `web/app/views/sitemap/origins/_filters.html.erb`
- Modify: `web/app/views/sitemap/origins/index.html.erb` (render the panel)
- Test: `web/test/integration/sitemap/origins_test.rb` (extend)

**Interfaces:**
- Consumes: `@method_options`, `@programs`, `@min_count`, `@filter`, `@program`, `@scheme` (Task 3).
- Produces: a collapsible GET `<form>` of filter controls that reloads `sitemap_root_path`.

- [ ] **Step 1: Write the failing test** (append to `web/test/integration/sitemap/origins_test.rb`)

```ruby
  test "filter panel renders controls and echoes active values" do
    a = target!(host: "f.host"); a.update!(program: "atg"); endpoint!(a, "/x", method: "POST")
    get sitemap_root_path(methods: ["POST"], min_count: 2, program: "atg", status: ["2"], path: "x", has_query: "1")
    assert_response :success
    assert_select "form[action=?][method=get]", sitemap_root_path
    assert_select "input[name='min_count'][value='2']"
    assert_select "input[name='methods[]'][value='POST'][checked]"
    assert_select "input[name='status[]'][value='2'][checked]"
    assert_select "input[name='path'][value='x']"
    assert_select "select[name='program'] option[selected][value='atg']"
    assert_select "input[name='has_query'][checked]"
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bin/rails test test/integration/sitemap/origins_test.rb`
Expected: FAIL — no filter form yet.

- [ ] **Step 3: Write the filters partial**

```erb
<%# web/app/views/sitemap/origins/_filters.html.erb %>
<details class="border-b border-zinc-200 px-2 py-2 dark:border-zinc-800" <%= "open" if @filter.present? || @program || @scheme || @min_count != 1 %>>
  <summary class="cursor-pointer select-none text-xs font-semibold uppercase tracking-wide text-zinc-500 dark:text-zinc-400">Filters</summary>
  <%= form_with url: sitemap_root_path, method: :get, class: "mt-2 space-y-3 text-sm" do %>
    <% if @q.present? %><input type="hidden" name="q" value="<%= @q %>" /><% end %>

    <div>
      <div class="mb-1 text-xs text-zinc-500">Method</div>
      <div class="flex flex-wrap gap-2">
        <% @method_options.each do |m| %>
          <label class="inline-flex items-center gap-1">
            <input type="checkbox" name="methods[]" value="<%= m %>" <%= "checked" if Array(@filter["methods"]).include?(m) %> />
            <span><%= m %></span>
          </label>
        <% end %>
      </div>
    </div>

    <div>
      <div class="mb-1 text-xs text-zinc-500">Status</div>
      <div class="flex flex-wrap gap-2">
        <% %w[2 3 4 5].each do |f| %>
          <label class="inline-flex items-center gap-1">
            <input type="checkbox" name="status[]" value="<%= f %>" <%= "checked" if Array(@filter["status"]).include?(f) %> />
            <span><%= f %>xx</span>
          </label>
        <% end %>
      </div>
    </div>

    <label class="block">
      <span class="text-xs text-zinc-500">Path contains</span>
      <input type="text" name="path" value="<%= @filter["path"] %>" class="mt-1 w-full rounded border border-zinc-300 bg-white px-2 py-1 dark:border-zinc-700 dark:bg-[#111315]" />
    </label>

    <label class="block">
      <span class="text-xs text-zinc-500">Content-type</span>
      <input type="text" name="content_type" value="<%= @filter["content_type"] %>" class="mt-1 w-full rounded border border-zinc-300 bg-white px-2 py-1 dark:border-zinc-700 dark:bg-[#111315]" />
    </label>

    <label class="inline-flex items-center gap-1">
      <input type="checkbox" name="has_query" value="1" <%= "checked" if @filter["has_query"].present? %> />
      <span>Has parameter (query)</span>
    </label>

    <label class="block">
      <span class="text-xs text-zinc-500">Program</span>
      <select name="program" class="mt-1 w-full rounded border border-zinc-300 bg-white px-2 py-1 dark:border-zinc-700 dark:bg-[#111315]">
        <option value="">Any</option>
        <% @programs.each do |p| %><option value="<%= p %>" <%= "selected" if @program == p %>><%= p %></option><% end %>
      </select>
    </label>

    <label class="block">
      <span class="text-xs text-zinc-500">Scheme</span>
      <select name="scheme" class="mt-1 w-full rounded border border-zinc-300 bg-white px-2 py-1 dark:border-zinc-700 dark:bg-[#111315]">
        <option value="">Any</option>
        <option value="https" <%= "selected" if @scheme == "https" %>>https</option>
        <option value="http" <%= "selected" if @scheme == "http" %>>http</option>
      </select>
    </label>

    <label class="block">
      <span class="text-xs text-zinc-500">Min endpoints</span>
      <input type="number" name="min_count" min="0" value="<%= @min_count %>" class="mt-1 w-24 rounded border border-zinc-300 bg-white px-2 py-1 dark:border-zinc-700 dark:bg-[#111315]" />
    </label>

    <div class="flex items-center gap-3 pt-1">
      <button type="submit" class="rounded bg-zinc-900 px-3 py-1 text-white dark:bg-zinc-100 dark:text-zinc-900">Apply</button>
      <a href="<%= sitemap_root_path %>" class="text-zinc-500 hover:underline">Clear</a>
    </div>
  <% end %>
</details>
```

- [ ] **Step 4: Render the panel in the index** (in `web/app/views/sitemap/origins/index.html.erb`, add the filters partial right after the search form, before the tree container)

```erb
    <%= render "sitemap/origins/filters" %>
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd web && bin/rails test test/integration/sitemap/origins_test.rb`
Expected: PASS.

- [ ] **Step 6: Run the whole sitemap suite**

Run: `cd web && bin/rails test test/services/sitemap/ test/integration/sitemap/`
Expected: all green.

- [ ] **Step 7: Commit**

```bash
git add web/app/views/sitemap/origins/_filters.html.erb web/app/views/sitemap/origins/index.html.erb \
  web/test/integration/sitemap/origins_test.rb
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Add the sitemap filter panel"
```

---

## Final verification

- [ ] **Full sitemap suite**

Run: `cd web && bin/rails test test/services/sitemap/ test/integration/sitemap/`
Expected: green.

- [ ] **Whole suite (excluding the known-broken pre-existing file)**

Run: `cd web && bin/rails test $(find test -name '*_test.rb' ! -path 'test/integration/api/runner/jobs_test.rb')`
Expected: green.

- [ ] **Live smoke (stack up, user):** `/sitemap` shows elbow-connected tree with SVG icons; non-GET endpoints show a method chip; parameterized endpoints are red; the filter panel narrows origins (0-endpoint origins hidden by default) and the per-origin tree honors the active filters.
