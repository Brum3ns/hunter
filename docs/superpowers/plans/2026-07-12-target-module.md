# Target Module Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Target department to Hunter — a column-configurable table of "alive" assets with brand-icon technology badges, backed by the `alive` MongoDB collection and a read-only JSON API.

**Architecture:** New `Targets` module mirroring the existing `Vulnerabilities` module: a `Targets::MongoSource` service reads the `alive` collection, a `Target` PORO normalizes docs, a `TargetsController` renders the web department, and `Api::V1::TargetsController` exposes index/show. Technology icons use a vendored Simple Icons dataset (single `icons.json`) resolved by a `SimpleIcons` lookup service and rendered by a `tech_icon_tag` helper. Column show/hide/reorder/resize is a client-only Stimulus controller persisting to `localStorage`.

**Tech Stack:** Ruby 3.3.6, Rails 8, Tailwind v4, importmap + Stimulus, Minitest, MongoDB (doubled in tests), Simple Icons (vendored, MIT).

## Global Constraints

- Ruby module namespace is `Hunter`; Rails app lives in `web/`. All commands below run from `web/`.
- **Do NOT touch the Control Center area** (`*control_center*` files) — another agent is working there.
- Module API controllers subclass `Api::V1::BaseController`; use `pagination_page` / `clamped_limit` / `render_not_found`.
- Mongo **reads swallow `Mongo::Error`** (→ empty/nil); this module has no writes.
- Tests never touch live Mongo — double the collection; use the `stub_methods` helper from `test/test_helper.rb`.
- Icons: **no runtime gem.** Vendor a pinned Simple Icons release as data; hand-roll the lookup + inline-SVG render (same technique as `IconHelper#heroicon`).
- Commit author is `Claude <noreply@anthropic.com>`; commit messages are a single sentence. **Only commit when steps say to.**
- Design language is monochrome; the only color exceptions are HTTP status badges (by family) and brand-colored tech icons.

---

## Status (2026-07-12)

**Landed (built + tested; Tasks 1–8 below are kept as the historical record):**
Simple Icons vendoring, `SimpleIcons` service, `TargetsHelper` + `tech_icon_tag`,
`Target` model, `Targets::MongoSource` (simple search), JSON API, the web
department (route/nav/icon/controller/views), and the `targets-columns` Stimulus
controller.

**Landed beyond the original plan (also tested):**
- **Detail side panel** — `TargetsController#show` + `web/config/routes.rb`
  `get "targets/:id"` + `app/views/targets/{show,_panel,_field}.html.erb` +
  `side_panel_controller.js` / `rowlink_controller.js` / `copyable_controller.js`.
  Covered by `test/integration/targets/show_test.rb` and the panel assertions in
  `index_test.rb`.
- **Infinite scroll** — `@next_page_url` + XHR `_rows_page` fragment in
  `TargetsController#index` + `app/views/targets/_rows_page.html.erb` +
  `targets_infinite_controller.js`. Covered by the infinite-scroll assertions in
  `index_test.rb`.
- **Enriched `Target` model** — added `input, headers, csp, fingerprint, tool,
  scan_id, failed, phash` accessors for the detail panel (see `target_test.rb`).

**Remaining (Tasks 9–12 below):** the dork search DSL. `Targets::SearchParser`
and `Targets::DorkExpression` are written but **not tested** and **not wired** —
the controllers still pass the raw query string as a plain substring search and
`MongoSource#build_filter` never consults the AST. Tasks 9–12 test both services,
thread `expression:` through `MongoSource`, and wire both controllers.

---

### Task 1: Vendor the Simple Icons dataset

Generate a single pinned data file from the official `simple-icons` npm package (no runtime dependency; the package is used once, at vendor time, then discarded).

**Files:**
- Create: `web/vendor/simple-icons/icons.json`
- Create: `web/vendor/simple-icons/VERSION`
- Create: `web/vendor/simple-icons/generate.mjs` (the one-time generator, checked in for reproducibility)

**Interfaces:**
- Produces: `web/vendor/simple-icons/icons.json` shaped `{ "<slug>": { "title": String, "hex": String, "path": String }, ... }`. Consumed by `SimpleIcons` (Task 2).

- [ ] **Step 1: Write the generator script**

Create `web/vendor/simple-icons/generate.mjs`:

```js
// One-time generator: extracts {slug,title,hex,path} for every Simple Icon into
// icons.json. Run with the pinned simple-icons version installed (see VERSION).
// Usage (from web/vendor/simple-icons/):
//   npm i simple-icons@16.26.0 --no-save --prefix /tmp/si && node generate.mjs /tmp/si
import { readFileSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";

const prefix = process.argv[2] || "/tmp/si";
const require = createRequire(prefix + "/node_modules/simple-icons/package.json");
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
```

- [ ] **Step 2: Generate the data and pin the version**

Run:

```bash
cd web/vendor/simple-icons
npm i simple-icons@16.26.0 --no-save --prefix /tmp/si
node generate.mjs /tmp/si
printf 'simple-icons@16.26.0\n' > VERSION
```

Expected: `wrote 3300` (or similar count > 3000), and `icons.json` exists.

- [ ] **Step 3: Sanity-check the data shape**

Run:

```bash
cd web/vendor/simple-icons
node -e "const d=require('./icons.json'); console.log(d.php.title, d.php.hex, typeof d.php.path); console.log('rails:', !!d.rubyonrails, 'nginx:', !!d.nginx, 'cloudflare:', !!d.cloudflare)"
```

Expected: prints `PHP <hex> string` and `rails: true nginx: true cloudflare: true`.

- [ ] **Step 4: Commit**

```bash
git add web/vendor/simple-icons/
git commit -m "Vendor a pinned Simple Icons dataset for technology brand icons"
```

---

### Task 2: `SimpleIcons` lookup service

Resolve an arbitrary technology name (from httpx/Wappalyzer `tech[]`) to a Simple Icons record.

**Files:**
- Create: `web/app/services/simple_icons.rb`
- Test: `web/test/services/simple_icons_test.rb`

**Interfaces:**
- Consumes: `web/vendor/simple-icons/icons.json` (Task 1).
- Produces: `SimpleIcons.lookup(name) -> { slug:, title:, hex:, path: }` or `nil`; `SimpleIcons.normalize(name) -> String`. Consumed by `TargetsHelper#tech_icon_tag` (Task 3).

- [ ] **Step 1: Write the failing test**

Create `web/test/services/simple_icons_test.rb`:

```ruby
require "test_helper"

class SimpleIconsTest < ActiveSupport::TestCase
  test "looks up a plain lowercase technology name" do
    icon = SimpleIcons.lookup("php")
    assert_equal "php", icon[:slug]
    assert_equal "PHP", icon[:title]
    assert_match(/\A[0-9A-Fa-f]{6}\z/, icon[:hex])
    assert icon[:path].present?
  end

  test "normalizes case and punctuation before matching" do
    assert_equal "nginx", SimpleIcons.lookup("Nginx")[:slug]
    assert_equal "wordpress", SimpleIcons.lookup("WordPress")[:slug]
  end

  test "resolves aliases for names that do not map to a slug" do
    assert_equal "rubyonrails", SimpleIcons.lookup("Ruby on Rails")[:slug]
    assert_equal "nodedotjs", SimpleIcons.lookup("Node.js")[:slug]
  end

  test "returns nil for unknown or blank names" do
    assert_nil SimpleIcons.lookup("totally-not-a-real-tech-xyz")
    assert_nil SimpleIcons.lookup("")
    assert_nil SimpleIcons.lookup(nil)
  end

  test "normalize strips non-alphanumerics and downcases" do
    assert_equal "socketio", SimpleIcons.normalize("Socket.IO")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/simple_icons_test.rb`
Expected: FAIL with `uninitialized constant SimpleIcons`.

- [ ] **Step 3: Write the service**

Create `web/app/services/simple_icons.rb`:

```ruby
# Resolves a technology name (as it appears in an httpx `tech[]` array) to a
# vendored Simple Icons record. Data is the pinned icons.json (see
# vendor/simple-icons/VERSION); no runtime gem. Lookup normalizes the name to
# Simple Icons' slug shape, with an ALIASES table for names that don't map
# cleanly. ALIASES is the single place to add new mismatches.
module SimpleIcons
  module_function

  DATA_PATH = Rails.root.join("vendor", "simple-icons", "icons.json")

  # Names whose normalized form differs from the icon's slug.
  ALIASES = {
    "ruby on rails"       => "rubyonrails",
    "rails"               => "rubyonrails",
    "node.js"             => "nodedotjs",
    "vue.js"              => "vuedotjs",
    "next.js"             => "nextdotjs",
    "nuxt.js"             => "nuxtdotjs",
    "express.js"          => "express",
    "google analytics"    => "googleanalytics",
    "google tag manager"  => "googletagmanager",
    "amazon web services" => "amazonaws",
    "aws"                 => "amazonaws",
    "amazon cloudfront"   => "amazoncloudfront",
    "microsoft asp.net"   => "dotnet",
    "asp.net"             => "dotnet"
  }.freeze

  def data
    @data ||= JSON.parse(File.read(DATA_PATH)).freeze
  end

  def lookup(name)
    return nil if name.blank?

    slug = ALIASES[name.to_s.strip.downcase]
    slug ||= (key = normalize(name); data.key?(key) ? key : nil)
    return nil unless slug && data.key?(slug)

    icon = data[slug]
    { slug: slug, title: icon["title"], hex: icon["hex"], path: icon["path"] }
  end

  def normalize(name)
    name.to_s.downcase.gsub(/[^a-z0-9]/, "")
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/services/simple_icons_test.rb`
Expected: PASS (5 runs, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add app/services/simple_icons.rb test/services/simple_icons_test.rb
git commit -m "Add SimpleIcons lookup service resolving technology names to vendored brand icons"
```

---

### Task 3: `tech_icon_tag` helper + monogram fallback

Render a single technology as an inline brand-colored SVG, or a neutral monogram chip when unmatched.

**Files:**
- Create: `web/app/helpers/targets_helper.rb`
- Test: `web/test/helpers/targets_helper_test.rb`

**Interfaces:**
- Consumes: `SimpleIcons.lookup` (Task 2).
- Produces: `TargetsHelper#tech_icon_tag(name, size: 4) -> html_safe String`; `TargetsHelper::COLUMNS` (Array of `{ key:, label:, width:, default: }`); `TargetsHelper#target_cell_value(target, key)`. Consumed by the views (Task 7).

- [ ] **Step 1: Write the failing test**

Create `web/test/helpers/targets_helper_test.rb`:

```ruby
require "test_helper"

class TargetsHelperTest < ActionView::TestCase
  include TargetsHelper

  test "renders a brand-colored svg for a known technology" do
    html = tech_icon_tag("php")
    assert_includes html, "<svg"
    assert_includes html, "fill=\"##{SimpleIcons.lookup('php')[:hex]}\""
    assert_includes html, "title=\"PHP\""
    assert html.html_safe?
  end

  test "renders a monogram chip for an unknown technology" do
    html = tech_icon_tag("madeupframeworkxyz")
    refute_includes html, "<svg"
    assert_includes html, "MA"
    assert_includes html, "title=\"madeupframeworkxyz\""
    assert html.html_safe?
  end

  test "COLUMNS lists host first and marks the design's default-visible set" do
    assert_equal "host", TargetsHelper::COLUMNS.first[:key]
    visible = TargetsHelper::COLUMNS.select { |c| c[:default] }.map { |c| c[:key] }
    assert_equal %w[host port ip technologies status title], visible
  end

  test "target_cell_value maps a column key to the target accessor" do
    target = Target.new("target" => { "host" => "a.example.com", "method" => "GET" })
    assert_equal "a.example.com", target_cell_value(target, "host")
    assert_equal "GET", target_cell_value(target, "method")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/helpers/targets_helper_test.rb`
Expected: FAIL with `uninitialized constant TargetsHelper` (or `Target`, addressed in Task 4 — run this test again after Task 4).

- [ ] **Step 3: Write the helper**

Create `web/app/helpers/targets_helper.rb`:

```ruby
module TargetsHelper
  # Single source of truth for the table's columns: order, label, default pixel
  # width, and whether it shows by default. The client column controller reads
  # these from the rendered header; adding a column is one entry here plus a
  # branch in target_cell_value.
  COLUMNS = [
    { key: "host",           label: "Host",         width: 240, default: true },
    { key: "port",           label: "Port",         width: 90,  default: true },
    { key: "ip",             label: "IP",           width: 150, default: true },
    { key: "technologies",   label: "Technologies", width: 170, default: true },
    { key: "status",         label: "Status",       width: 90,  default: true },
    { key: "title",          label: "Title",        width: 240, default: true },
    { key: "url",            label: "URL",          width: 260, default: false },
    { key: "scheme",         label: "Scheme",       width: 90,  default: false },
    { key: "path",           label: "Path",         width: 160, default: false },
    { key: "method",         label: "Method",       width: 90,  default: false },
    { key: "webserver",      label: "Web Server",   width: 150, default: false },
    { key: "content_type",   label: "Content-Type", width: 170, default: false },
    { key: "content_length", label: "Length",       width: 110, default: false },
    { key: "words",          label: "Words",        width: 90,  default: false },
    { key: "lines",          label: "Lines",        width: 90,  default: false },
    { key: "response_time",  label: "Resp. Time",   width: 120, default: false },
    { key: "program",        label: "Program",      width: 160, default: false },
    { key: "page_type",      label: "Page Type",    width: 140, default: false }
  ].freeze

  # Non-special columns render their plain value through this map.
  def target_cell_value(target, key)
    case key
    when "host"           then target.host
    when "port"           then target.port
    when "ip"             then target.ip
    when "status"         then target.status_code
    when "title"          then target.title
    when "url"            then target.url
    when "scheme"         then target.scheme
    when "path"           then target.path
    when "method"         then target.verb
    when "webserver"      then target.webserver
    when "content_type"   then target.content_type
    when "content_length" then target.content_length
    when "words"          then target.words
    when "lines"          then target.lines
    when "response_time"  then target.response_time
    when "program"        then target.program
    when "page_type"      then target.page_type
    end
  end

  # One technology → inline brand-colored SVG, or a neutral monogram chip when
  # Simple Icons has no match. `size` is a Tailwind h-/w- scale number.
  def tech_icon_tag(name, size: 4)
    icon = SimpleIcons.lookup(name)
    dim = "h-#{size} w-#{size}"

    if icon
      svg = content_tag(:svg, tag.path(d: icon[:path]),
        xmlns: "http://www.w3.org/2000/svg", viewBox: "0 0 24 24",
        fill: "##{icon[:hex]}", "aria-hidden": "true", class: dim)
      content_tag(:span, svg,
        class: "inline-flex items-center justify-center rounded bg-white/5 p-1",
        title: icon[:title])
    else
      content_tag(:span, tech_monogram_text(name),
        class: "inline-flex #{dim} items-center justify-center rounded bg-white/10 " \
               "p-1 text-[9px] font-semibold uppercase leading-none text-zinc-300",
        title: name.to_s)
    end
  end

  private

  def tech_monogram_text(name)
    name.to_s.gsub(/[^A-Za-z0-9]/, "").first(2).upcase
  end
end
```

- [ ] **Step 4: Run test to verify it passes** (after Task 4's `Target` exists)

Run: `bin/rails test test/helpers/targets_helper_test.rb`
Expected: PASS (4 runs, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add app/helpers/targets_helper.rb test/helpers/targets_helper_test.rb
git commit -m "Add TargetsHelper with column defs and a technology icon helper with monogram fallback"
```

---

### Task 4: `Target` model PORO

**Files:**
- Create: `web/app/models/target.rb`
- Test: `web/test/models/target_test.rb`

**Interfaces:**
- Produces: `Target.new(hash)` with readers `id, host, url, ip, port, scheme, path, verb, status_code, title, webserver, content_type, content_length, words, lines, response_time, tech (Array), program, page_type, seen_at, status_family`; `#as_json`. Consumed by controllers, helper, and views.

- [ ] **Step 1: Write the failing test**

Create `web/test/models/target_test.rb`:

```ruby
require "test_helper"

class TargetTest < ActiveSupport::TestCase
  DOC = {
    "id" => "abc",
    "metadata" => { "program" => "acme", "date" => "2026-02-01T00:00:00Z" },
    "target" => { "url" => "https://a.example.com", "host" => "a.example.com",
                  "ip" => "1.2.3.4", "port" => "443", "scheme" => "https",
                  "path" => "/", "method" => "GET" },
    "http" => { "status_code" => 200, "title" => "Home", "webserver" => "nginx",
                "content_type" => "text/html", "content_length" => 12,
                "words" => 3, "lines" => 1, "response_time" => "120ms" },
    "tech" => ["PHP", "Nginx"],
    "fingerprint" => { "page_type" => "other" }
  }.freeze

  test "maps nested document fields to flat accessors" do
    t = Target.new(DOC)
    assert_equal "abc", t.id
    assert_equal "a.example.com", t.host
    assert_equal "443", t.port
    assert_equal "GET", t.verb
    assert_equal 200, t.status_code
    assert_equal "nginx", t.webserver
    assert_equal %w[PHP Nginx], t.tech
    assert_equal "acme", t.program
    assert_equal "other", t.page_type
    assert_equal "2026-02-01T00:00:00Z", t.seen_at
  end

  test "tech is always an array even when missing" do
    assert_equal [], Target.new({}).tech
  end

  test "status_family buckets the status code" do
    assert_equal "2xx", Target.new("http" => { "status_code" => 200 }).status_family
    assert_equal "3xx", Target.new("http" => { "status_code" => 301 }).status_family
    assert_equal "4xx", Target.new("http" => { "status_code" => 404 }).status_family
    assert_equal "5xx", Target.new("http" => { "status_code" => 500 }).status_family
    assert_equal "other", Target.new({}).status_family
  end

  test "as_json returns the underlying attributes" do
    assert_equal "acme", Target.new(DOC).as_json["metadata"]["program"]
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/target_test.rb`
Expected: FAIL with `uninitialized constant Target`.

- [ ] **Step 3: Write the model**

Create `web/app/models/target.rb`:

```ruby
# PORO wrapping a normalized "alive" asset document read from MongoDB (see
# tmp/db_struct/alive.json). Not persisted in Postgres — construct from a hash
# via Target.new(hash). `verb` avoids clobbering Object#method.
class Target
  attr_reader :id, :attributes

  def initialize(attrs = {})
    @attributes = attrs.to_h.transform_keys(&:to_s)
    @id = @attributes["id"]
  end

  def metadata = @attributes["metadata"] || {}
  def target   = @attributes["target"] || {}
  def http     = @attributes["http"] || {}
  def tech     = Array(@attributes["tech"])

  def host           = target["host"]
  def url            = target["url"]
  def ip             = target["ip"]
  def port           = target["port"]
  def scheme         = target["scheme"]
  def path           = target["path"]
  def verb           = target["method"]
  def status_code    = http["status_code"]
  def title          = http["title"]
  def webserver      = http["webserver"]
  def content_type   = http["content_type"]
  def content_length = http["content_length"]
  def words          = http["words"]
  def lines          = http["lines"]
  def response_time  = http["response_time"]
  def program        = metadata["program"]
  def seen_at        = metadata["date"]
  def page_type      = (@attributes["fingerprint"] || {})["page_type"]

  def status_family
    case status_code.to_i
    when 200..299 then "2xx"
    when 300..399 then "3xx"
    when 400..499 then "4xx"
    when 500..599 then "5xx"
    else "other"
    end
  end

  def as_json(*) = @attributes
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/models/target_test.rb`
Expected: PASS (5 runs, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add app/models/target.rb test/models/target_test.rb
git commit -m "Add Target model PORO wrapping normalized alive documents"
```

---

### Task 5: `Targets::MongoSource` service

**Files:**
- Create: `web/app/services/targets/mongo_source.rb`
- Test: `web/test/services/targets/mongo_source_test.rb`

**Interfaces:**
- Produces: `Targets::MongoSource.all(filters:, search:, sort:, dir:, page:, limit:) -> Array<Hash>`, `.count(filters:, search:) -> Integer`, `.find(id) -> Hash|nil`. Consumed by both controllers (Tasks 6, 7).

- [ ] **Step 1: Write the failing test**

Create `web/test/services/targets/mongo_source_test.rb`:

```ruby
require "test_helper"

class Targets::MongoSourceTest < ActiveSupport::TestCase
  class FakeQuery
    def initialize(docs) = @docs = docs
    attr_reader :last_sort
    def sort(spec) = (@last_sort = spec; self)
    def skip(*) = self
    def limit(*) = self
    def to_a = @docs
  end

  class FakeCollection
    attr_reader :last_filter, :query
    def initialize(docs) = @docs = docs
    def find(filter = {})
      @last_filter = filter
      @query = FakeQuery.new(@docs)
    end
  end

  test "all normalizes documents and defaults to date-desc sort" do
    oid = BSON::ObjectId.new
    collection = FakeCollection.new([{ "_id" => oid, "target" => { "host" => "a" } }])

    stub_methods(HunterMongo, ensure_indexes_once!: true, collection: collection) do
      result = Targets::MongoSource.all(limit: 10)
      assert_equal oid.to_s, result.first["id"]
      assert_not result.first.key?("_id")
      assert_equal({ "metadata.date" => -1 }, collection.query.last_sort)
    end
  end

  test "all maps a whitelisted sort key and ascending direction" do
    collection = FakeCollection.new([])
    stub_methods(HunterMongo, ensure_indexes_once!: true, collection: collection) do
      Targets::MongoSource.all(sort: "host", dir: "asc", limit: 10)
      assert_equal({ "target.host" => 1 }, collection.query.last_sort)
    end
  end

  test "all builds a search $or across host, ip, title and tech" do
    collection = FakeCollection.new([])
    stub_methods(HunterMongo, ensure_indexes_once!: true, collection: collection) do
      Targets::MongoSource.all(search: "nginx", limit: 10)
      assert_equal(
        [
          { "target.host" => { "$regex" => "nginx", "$options" => "i" } },
          { "target.ip"   => { "$regex" => "nginx", "$options" => "i" } },
          { "http.title"  => { "$regex" => "nginx", "$options" => "i" } },
          { "tech"        => { "$regex" => "nginx", "$options" => "i" } }
        ],
        collection.last_filter["$or"]
      )
    end
  end

  test "all maps allowed filters and drops blanks and unknowns" do
    collection = FakeCollection.new([])
    stub_methods(HunterMongo, ensure_indexes_once!: true, collection: collection) do
      Targets::MongoSource.all(filters: { "program" => "acme", "nope" => "x", "status" => "" }, limit: 10)
      assert_equal({ "metadata.program" => "acme" }, collection.last_filter)
    end
  end

  test "all swallows Mongo errors and returns an empty array" do
    stub_methods(HunterMongo, ensure_indexes_once!: true, collection: ->(*) { raise Mongo::Error.new("down") }) do
      assert_equal [], Targets::MongoSource.all(limit: 10)
    end
  end

  test "find returns nil for a malformed id without hitting Mongo" do
    assert_nil Targets::MongoSource.find("not-an-oid")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/targets/mongo_source_test.rb`
Expected: FAIL with `uninitialized constant Targets::MongoSource`.

- [ ] **Step 3: Write the service**

Create `web/app/services/targets/mongo_source.rb`:

```ruby
module Targets
  # Read-only access to the MongoDB `alive` collection (httpx probe output; see
  # tmp/db_struct/alive.json). Mirrors Vulnerabilities::MongoSource but without
  # writes. Reads never raise to the caller — a Mongo outage yields empty/nil.
  module MongoSource
    module_function

    COLLECTION = ENV.fetch("MONGO_ALIVE_COLLECTION", "alive")

    INDEXES = [
      { key: { "target.host": 1 },      name: "target_host" },
      { key: { "target.ip": 1 },        name: "target_ip" },
      { key: { "http.status_code": 1 }, name: "http_status_code" },
      { key: { "metadata.program": 1 }, name: "metadata_program" },
      { key: { "metadata.date": -1 },   name: "metadata_date" }
    ].freeze

    # Public filter key -> nested Mongo field. Anything else is ignored.
    FILTER_KEYS = {
      "program" => "metadata.program",
      "status"  => "http.status_code"
    }.freeze

    # Free-text search matches any of these (case-insensitive).
    SEARCH_FIELDS = %w[target.host target.ip http.title tech].freeze

    # Public sort key -> Mongo field. Unknown keys fall back to DEFAULT_SORT.
    SORT_FIELDS = {
      "host"   => "target.host",
      "ip"     => "target.ip",
      "port"   => "target.port",
      "status" => "http.status_code",
      "title"  => "http.title",
      "date"   => "metadata.date"
    }.freeze
    DEFAULT_SORT = "date"

    def all(filters: {}, search: nil, sort: DEFAULT_SORT, dir: "desc", page: 1, limit: 50)
      HunterMongo.ensure_indexes_once!(COLLECTION, INDEXES)
      skip = ([page.to_i, 1].max - 1) * limit
      docs = collection.find(build_filter(filters, search))
                       .sort(sort_spec(sort, dir))
                       .skip(skip)
                       .limit(limit)
                       .to_a
      docs.map { |doc| normalize(doc) }
    rescue Mongo::Error => e
      Rails.logger.warn("Targets::MongoSource#all failed (#{e.class}: #{e.message})")
      []
    end

    def count(filters: {}, search: nil)
      collection.count_documents(build_filter(filters, search))
    rescue Mongo::Error => e
      Rails.logger.warn("Targets::MongoSource#count failed (#{e.class}: #{e.message})")
      0
    end

    def find(id)
      oid = to_object_id(id)
      return nil unless oid
      doc = collection.find(_id: oid).first
      doc && normalize(doc)
    rescue Mongo::Error => e
      Rails.logger.warn("Targets::MongoSource#find failed (#{e.class}: #{e.message})")
      nil
    end

    def collection
      HunterMongo.collection(COLLECTION)
    end

    def sort_spec(sort, dir)
      field = SORT_FIELDS[sort.to_s] || SORT_FIELDS[DEFAULT_SORT]
      { field => (dir.to_s == "asc" ? 1 : -1) }
    end
    private_class_method :sort_spec

    def build_filter(filters, search = nil)
      base = filters.to_h.each_with_object({}) do |(key, value), mongo|
        next if value.blank?
        mongo_key = FILTER_KEYS[key.to_s]
        mongo[mongo_key] = value if mongo_key
      end
      if search.present?
        rx = { "$regex" => Regexp.escape(search.to_s), "$options" => "i" }
        base["$or"] = SEARCH_FIELDS.map { |field| { field => rx } }
      end
      base
    end
    private_class_method :build_filter

    def to_object_id(id)
      BSON::ObjectId.from_string(id.to_s)
    rescue BSON::Error::InvalidObjectId
      nil
    end
    private_class_method :to_object_id

    def normalize(doc)
      hash = doc.to_h.transform_keys(&:to_s)
      oid = hash.delete("_id")
      hash["id"] = oid.to_s if oid
      hash
    end
    private_class_method :normalize
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/services/targets/mongo_source_test.rb`
Expected: PASS (6 runs, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add app/services/targets/mongo_source.rb test/services/targets/mongo_source_test.rb
git commit -m "Add Targets::MongoSource reading the alive collection with search, sort and filters"
```

---

### Task 6: JSON API — `Api::V1::TargetsController`

**Files:**
- Create: `web/app/controllers/api/v1/targets_controller.rb`
- Modify: `web/config/routes.rb` (add `resources :targets` inside `namespace :api { namespace :v1 }`)
- Test: `web/test/integration/api/v1/targets_test.rb`

**Interfaces:**
- Consumes: `Targets::MongoSource` (Task 5), `Target` (Task 4).
- Produces: `GET /api/v1/targets` → `{ count:, page:, limit:, targets: [...] }`; `GET /api/v1/targets/:id` → target JSON or 404.

- [ ] **Step 1: Add the route**

In `web/config/routes.rb`, inside `namespace :api do namespace :v1 do`, add a sibling block after the `resources :vulnerabilities` line:

```ruby
      # Target module: read-only list + detail over the alive collection.
      resources :targets, only: %i[index show]
```

- [ ] **Step 2: Write the failing test**

Create `web/test/integration/api/v1/targets_test.rb`:

```ruby
require "test_helper"

class Api::V1::TargetsTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }

  Source = Targets::MongoSource

  test "returns 401 without a cookie or token" do
    get "/api/v1/targets"
    assert_response :unauthorized
    assert_equal "unauthorized", JSON.parse(response.body)["error"]
  end

  test "index returns a paginated envelope for an authenticated user" do
    sign_in_as(@user)
    stub_methods(Source, all: [{ "id" => "1", "target" => { "host" => "a" } }], count: 1) do
      get "/api/v1/targets"
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal 1, body["count"]
      assert_equal 1, body["targets"].length
      assert_equal "a", body["targets"].first["target"]["host"]
    end
  end

  test "index passes search, sort and filters through and clamps the limit" do
    sign_in_as(@user)
    captured = nil
    capture = ->(filters:, search:, sort:, dir:, page:, limit:) {
      captured = { filters:, search:, sort:, dir:, page:, limit: }; []
    }
    stub_methods(Source, all: capture, count: 0) do
      get "/api/v1/targets", params: { q: "nginx", program: "acme", sort: "host", dir: "asc", page: "2", limit: "9999" }
    end
    assert_equal({ "program" => "acme" }, captured[:filters])
    assert_equal "nginx", captured[:search]
    assert_equal "host", captured[:sort]
    assert_equal "asc", captured[:dir]
    assert_equal 2, captured[:page]
    assert_equal 200, captured[:limit]
  end

  test "show returns the document or 404" do
    sign_in_as(@user)
    stub_methods(Source, find: { "id" => "abc", "target" => { "host" => "a" } }) do
      get "/api/v1/targets/abc"
      assert_response :success
      assert_equal "abc", JSON.parse(response.body)["id"]
    end
    stub_methods(Source, find: nil) do
      get "/api/v1/targets/missing"
      assert_response :not_found
    end
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bin/rails test test/integration/api/v1/targets_test.rb`
Expected: FAIL (routing error / `uninitialized constant Api::V1::TargetsController`).

- [ ] **Step 4: Write the controller**

Create `web/app/controllers/api/v1/targets_controller.rb`:

```ruby
module Api
  module V1
    # Target module API — read-only list + detail over the MongoDB `alive`
    # collection. Shares the service layer with the web department.
    class TargetsController < BaseController
      # GET /api/v1/targets
      def index
        filters = filter_params
        search  = params[:q].presence
        page    = pagination_page
        limit   = clamped_limit

        docs = Targets::MongoSource.all(
          filters: filters, search: search,
          sort: params[:sort], dir: params[:dir],
          page: page, limit: limit
        )
        render json: {
          count: Targets::MongoSource.count(filters: filters, search: search),
          page: page,
          limit: limit,
          targets: docs.map { |doc| Target.new(doc).as_json }
        }
      end

      # GET /api/v1/targets/:id
      def show
        doc = Targets::MongoSource.find(params[:id])
        return render_not_found unless doc

        render json: Target.new(doc).as_json
      end

      private

      def filter_params
        params.permit(:program, :status).to_h
      end
    end
  end
end
```

Note: `sort`/`dir` default inside `MongoSource` when `nil`, so passing `params[:sort]` (possibly nil) is safe.

- [ ] **Step 5: Run test to verify it passes**

Run: `bin/rails test test/integration/api/v1/targets_test.rb`
Expected: PASS (4 runs, 0 failures).

- [ ] **Step 6: Commit**

```bash
git add app/controllers/api/v1/targets_controller.rb config/routes.rb test/integration/api/v1/targets_test.rb
git commit -m "Add read-only Targets JSON API with search, sort and filter passthrough"
```

---

### Task 7: Web department — route, nav, controller, views

**Files:**
- Modify: `web/config/routes.rb` (add `get "targets"`)
- Modify: `web/app/helpers/navigation_helper.rb` (add the sidebar entry)
- Modify: `web/app/helpers/icon_helper.rb` (add a `target` heroicon path)
- Create: `web/app/controllers/targets_controller.rb`
- Create: `web/app/views/targets/index.html.erb`
- Create: `web/app/views/targets/_toolbar.html.erb`
- Create: `web/app/views/targets/_table.html.erb`
- Create: `web/app/views/targets/_row.html.erb`
- Create: `web/app/views/targets/_tech_icons.html.erb`
- Create: `web/app/views/targets/_status_badge.html.erb`
- Test: `web/test/integration/targets/index_test.rb`
- Test (modify): `web/test/helpers/icon_helper_test.rb` (assert the new glyph renders)

**Interfaces:**
- Consumes: `Targets::MongoSource` (Task 5), `Target` (Task 4), `TargetsHelper` (Task 3), `tech_icon_tag` (Task 3). The table markup emits `data-controller="targets-columns"` and per-cell `data-col` attributes consumed by Task 8's Stimulus controller.

- [ ] **Step 1: Add the web route**

In `web/config/routes.rb`, next to `get "cves", ...`, add:

```ruby
  get "targets", to: "targets#index"
```

- [ ] **Step 2: Add the sidebar entry**

In `web/app/helpers/navigation_helper.rb`, add to the second (modules) group array, after the Vulnerabilities entry:

```ruby
        { label: "Target", path: targets_path, controllers: %w[targets], icon: "target" },
```

- [ ] **Step 3: Add the `target` heroicon glyph + test**

In `web/app/helpers/icon_helper.rb`, add an entry to `HEROICON_PATHS` (a crosshair):

```ruby
    "target" => [
      "M12 3v3m0 12v3m9-9h-3M6 12H3m15 0a6 6 0 11-12 0 6 6 0 0112 0z"
    ],
```

In `web/test/helpers/icon_helper_test.rb`, extend the "renders new program-page glyphs" list (or add a new assertion) to include `target`:

```ruby
  test "renders the target department glyph" do
    assert_match(/<svg/, heroicon("target"))
  end
```

- [ ] **Step 4: Write the failing web integration test**

Create `web/test/integration/targets/index_test.rb`:

```ruby
require "test_helper"

class Targets::IndexTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }

  Source = Targets::MongoSource

  def stub_index(docs:, count:)
    stub_methods(Source, all: ->(*) { docs }, count: ->(*) { count }) { yield }
  end

  test "redirects an unauthenticated visitor to sign in" do
    get targets_path
    assert_redirected_to new_session_path
  end

  test "renders the table with default columns and marks the nav active" do
    sign_in_as(@user)
    doc = {
      "id" => "1",
      "target" => { "host" => "grafana.example.com", "ip" => "1.2.3.4", "port" => "443" },
      "http" => { "status_code" => 200, "title" => "Home" },
      "tech" => ["PHP"]
    }
    stub_index(docs: [doc], count: 1) do
      get targets_path
      assert_response :success
      assert_select "[data-controller~=targets-columns]"
      assert_select "[data-col=host]"
      assert_select "[data-col=technologies]"
      assert_select "a[href=?][aria-current=page]", targets_path
      assert_select "svg[title=PHP]"
    end
  end

  test "forwards q, sort and dir to the source" do
    sign_in_as(@user)
    captured = nil
    capture = ->(filters:, search:, sort:, dir:, page:, limit:) { captured = { search:, sort:, dir: }; [] }
    stub_methods(Source, all: capture, count: ->(*) { 0 }) do
      get targets_path, params: { q: "nginx", sort: "host", dir: "asc" }
    end
    assert_equal "nginx", captured[:search]
    assert_equal "host", captured[:sort]
    assert_equal "asc", captured[:dir]
  end
end
```

- [ ] **Step 5: Run test to verify it fails**

Run: `bin/rails test test/integration/targets/index_test.rb`
Expected: FAIL (`uninitialized constant TargetsController` / missing route).

- [ ] **Step 6: Write the controller**

Create `web/app/controllers/targets_controller.rb`:

```ruby
# Target department: a column-configurable table of "alive" assets. Renders HTML
# by calling Targets::MongoSource directly (the JSON API is a separate surface
# sharing the same service layer).
class TargetsController < ApplicationController
  DEFAULT_LIMIT = 50

  def index
    @filters = { "program" => params[:program].presence, "status" => params[:status].presence }.compact
    @search  = params[:q].presence
    @sort    = params[:sort].presence || Targets::MongoSource::DEFAULT_SORT
    @dir     = params[:dir] == "asc" ? "asc" : "desc"
    @page    = [params[:page].to_i, 1].max

    docs = Targets::MongoSource.all(
      filters: @filters, search: @search, sort: @sort, dir: @dir,
      page: @page, limit: DEFAULT_LIMIT
    )
    @targets = docs.map { |doc| Target.new(doc) }
    @total   = Targets::MongoSource.count(filters: @filters, search: @search)
  end
end
```

- [ ] **Step 7: Write the views**

Create `web/app/views/targets/index.html.erb`:

```erb
<% content_for :title, "Target" %>
<div class="flex min-h-dvh flex-col gap-4 p-4 text-white md:p-6">
  <form method="get" action="<%= targets_path %>" class="flex items-center gap-2">
    <span class="rounded-md border border-white/20 px-2 py-1 text-[11px] font-semibold tracking-wide text-zinc-300">AI</span>
    <input type="search" name="q" value="<%= @search %>" placeholder="Search your assets…"
           class="w-full rounded-lg border border-white/10 bg-white/5 px-3 py-2 text-sm text-white placeholder:text-zinc-500 focus:border-white/30 focus:outline-none" />
    <input type="hidden" name="sort" value="<%= @sort %>" />
    <input type="hidden" name="dir" value="<%= @dir %>" />
  </form>

  <%= render "toolbar" %>
  <%= render "table" %>
</div>
```

Create `web/app/views/targets/_toolbar.html.erb`:

```erb
<%# Summary count chips (display-only this pass) + column picker trigger. %>
<div data-targets-columns-target="toolbar" class="flex flex-wrap items-center gap-2">
  <span class="inline-flex items-center gap-1.5 rounded-lg bg-white/5 px-3 py-1.5 text-xs text-zinc-300">
    Assets <span class="rounded bg-white/10 px-1.5 py-0.5 font-semibold text-white"><%= @total %></span>
  </span>

  <div class="relative ml-auto">
    <details class="group">
      <summary class="flex cursor-pointer list-none items-center gap-1.5 rounded-lg bg-white/5 px-3 py-1.5 text-xs text-zinc-300 hover:bg-white/10">
        <%= heroicon "adjustments-horizontal", classes: "h-4 w-4" %> Columns
      </summary>
      <div class="absolute right-0 z-20 mt-1 w-52 rounded-lg border border-white/10 bg-[#0a0a0a] p-2 shadow-xl">
        <% TargetsHelper::COLUMNS.each do |col| %>
          <label class="flex items-center gap-2 rounded px-2 py-1.5 text-xs text-zinc-300 hover:bg-white/5">
            <input type="checkbox" data-action="targets-columns#toggle" data-col="<%= col[:key] %>"
                   <%= "checked" if col[:default] %> class="accent-white" />
            <%= col[:label] %>
          </label>
        <% end %>
      </div>
    </details>
  </div>
</div>
```

Create `web/app/views/targets/_table.html.erb`:

```erb
<div data-controller="targets-columns" class="overflow-x-auto rounded-xl border border-white/10">
  <%# Header row. Each header cell carries the column metadata the client
      controller needs: key, label, default width, default visibility. %>
  <div data-targets-columns-target="header"
       class="grid border-b border-white/10 bg-white/5 text-[11px] font-semibold uppercase tracking-wide text-zinc-400">
    <% TargetsHelper::COLUMNS.each do |col| %>
      <div class="group relative flex items-center gap-1 px-3 py-2.5" draggable="true"
           data-targets-columns-target="head" data-col="<%= col[:key] %>"
           data-label="<%= col[:label] %>" data-width="<%= col[:width] %>"
           data-default="<%= col[:default] %>"
           style="<%= "display:none" unless col[:default] %>">
        <%= link_to col[:label], targets_path(request.query_parameters.merge(sort: col[:key], dir: (@sort == col[:key] && @dir == "asc") ? "desc" : "asc")),
              class: "truncate hover:text-white" if Targets::MongoSource::SORT_FIELDS.key?(col[:key]) %>
        <% unless Targets::MongoSource::SORT_FIELDS.key?(col[:key]) %><span class="truncate"><%= col[:label] %></span><% end %>
        <span class="absolute right-0 top-0 h-full w-1 cursor-col-resize opacity-0 group-hover:opacity-100"
              data-action="mousedown->targets-columns#startResize" data-col="<%= col[:key] %>"></span>
      </div>
    <% end %>
  </div>

  <div data-targets-columns-target="body">
    <% if @targets.empty? %>
      <div class="px-4 py-10 text-center text-sm text-zinc-500">No assets found.</div>
    <% else %>
      <% @targets.each do |target| %>
        <%= render "row", target: target %>
      <% end %>
    <% end %>
  </div>
</div>
```

Create `web/app/views/targets/_row.html.erb`:

```erb
<div data-targets-columns-target="row"
     class="grid items-center border-b border-white/5 text-sm text-zinc-200 hover:bg-white/5">
  <% TargetsHelper::COLUMNS.each do |col| %>
    <div class="min-w-0 truncate px-3 py-2.5" data-col="<%= col[:key] %>"
         style="<%= "display:none" unless col[:default] %>">
      <% case col[:key] %>
      <% when "host" %>
        <div class="flex items-center justify-between gap-2">
          <span class="truncate font-mono text-[13px] text-white"><%= target.host %></span>
          <% if target.seen_at.present? %>
            <span class="shrink-0 text-[11px] text-emerald-500/80" title="<%= target.seen_at %>">
              <%= time_ago_in_words(Time.zone.parse(target.seen_at)) rescue nil %> ago
            </span>
          <% end %>
        </div>
      <% when "technologies" %>
        <%= render "tech_icons", tech: target.tech %>
      <% when "status" %>
        <%= render "status_badge", code: target.status_code, family: target.status_family %>
      <% else %>
        <span class="truncate font-mono text-[13px]"><%= target_cell_value(target, col[:key]) %></span>
      <% end %>
    </div>
  <% end %>
</div>
```

Create `web/app/views/targets/_tech_icons.html.erb`:

```erb
<% shown = Array(tech).first(4) %>
<div class="flex items-center gap-1">
  <% shown.each do |name| %>
    <%= tech_icon_tag(name, size: 4) %>
  <% end %>
  <% if Array(tech).length > shown.length %>
    <span class="rounded bg-white/10 px-1 text-[10px] font-semibold text-zinc-300">+<%= Array(tech).length - shown.length %></span>
  <% end %>
</div>
```

Create `web/app/views/targets/_status_badge.html.erb`:

```erb
<%
  klass = {
    "2xx" => "bg-emerald-500/15 text-emerald-400",
    "3xx" => "bg-sky-500/15 text-sky-400",
    "4xx" => "bg-amber-500/15 text-amber-400",
    "5xx" => "bg-red-500/15 text-red-400"
  }.fetch(family, "bg-white/10 text-zinc-300")
%>
<span class="inline-flex items-center rounded px-1.5 py-0.5 text-xs font-semibold <%= klass %>">
  <%= code.presence || "—" %>
</span>
```

- [ ] **Step 8: Run the web + icon tests to verify they pass**

Run: `bin/rails test test/integration/targets/index_test.rb test/helpers/icon_helper_test.rb`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add config/routes.rb app/helpers/navigation_helper.rb app/helpers/icon_helper.rb \
        app/controllers/targets_controller.rb app/views/targets/ \
        test/integration/targets/index_test.rb test/helpers/icon_helper_test.rb
git commit -m "Add the Target web department with a configurable asset table and sidebar entry"
```

---

### Task 8: Column show/hide, reorder, and resize (Stimulus + localStorage)

Client-only controller that reads column metadata from the rendered header, applies saved state, and persists `{order, hidden, widths}` to `localStorage`.

**Files:**
- Create: `web/app/javascript/controllers/targets_columns_controller.js`
- Test: `web/test/integration/targets/index_test.rb` (extend — assert the controller + resize handles are wired server-side)

**Interfaces:**
- Consumes: the DOM produced by Task 7 — `data-controller="targets-columns"`, targets `header`/`body`/`row`/`head`, per-cell `data-col`, and header `data-width`/`data-default`. Registered automatically by `eagerLoadControllersFrom("controllers", …)` (see `app/javascript/controllers/index.js`) — no importmap edit needed.

- [ ] **Step 1: Extend the web test with the wiring assertions**

Add to `web/test/integration/targets/index_test.rb` inside the "renders the table…" test (after the existing `assert_select` lines):

```ruby
      assert_select "[data-targets-columns-target=header]"
      assert_select "[data-action~=mousedown->targets-columns#startResize]"
      assert_select "input[data-action~=targets-columns#toggle][data-col=url]"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/integration/targets/index_test.rb`
Expected: FAIL on the new `assert_select` lines if any header wiring is missing (should pass if Task 7 markup is complete — if it passes already, these assertions simply lock the contract; proceed).

- [ ] **Step 3: Write the Stimulus controller**

Create `web/app/javascript/controllers/targets_columns_controller.js`:

```js
import { Controller } from "@hotwired/stimulus"

// Owns the asset table's column layout: visibility, order, and width. State is
// a single source of truth ({ order, hidden, widths }) persisted to
// localStorage and applied by rewriting each row's CSS grid template plus the
// `order`/`display` of every cell. Column metadata (default width/visibility)
// is read from the server-rendered header cells.
const STORAGE_KEY = "targets.columns"

export default class extends Controller {
  static targets = ["header", "body", "head", "row"]

  connect() {
    this.defaults = {}
    this.order = []
    this.headTargets.forEach((el) => {
      const col = el.dataset.col
      this.order.push(col)
      this.defaults[col] = {
        width: parseInt(el.dataset.width, 10) || 140,
        visible: el.dataset.default === "true"
      }
    })
    this.hidden = new Set(
      Object.keys(this.defaults).filter((c) => !this.defaults[c].visible)
    )
    this.widths = {}
    Object.keys(this.defaults).forEach((c) => (this.widths[c] = this.defaults[c].width))

    this.load()
    this.bindDragAndDrop()
    this.apply()
  }

  // --- persistence -------------------------------------------------------
  load() {
    try {
      const saved = JSON.parse(localStorage.getItem(STORAGE_KEY))
      if (!saved) return
      if (Array.isArray(saved.order)) {
        const known = new Set(this.order)
        const merged = saved.order.filter((c) => known.has(c))
        this.order.forEach((c) => { if (!merged.includes(c)) merged.push(c) })
        this.order = merged
      }
      if (Array.isArray(saved.hidden)) this.hidden = new Set(saved.hidden)
      if (saved.widths) Object.assign(this.widths, saved.widths)
    } catch (_e) { /* corrupt state — fall back to defaults */ }
  }

  save() {
    localStorage.setItem(STORAGE_KEY, JSON.stringify({
      order: this.order,
      hidden: [...this.hidden],
      widths: this.widths
    }))
  }

  // --- apply -------------------------------------------------------------
  apply() {
    const visible = this.order.filter((c) => !this.hidden.has(c))
    const template = visible.map((c) => `${this.widths[c]}px`).join(" ")

    ;[this.headerTarget, ...this.rowTargets].forEach((rowEl) => {
      rowEl.style.gridTemplateColumns = template
      rowEl.querySelectorAll("[data-col]").forEach((cell) => {
        const col = cell.dataset.col
        if (this.hidden.has(col)) {
          cell.style.display = "none"
        } else {
          cell.style.display = ""
          cell.style.order = String(visible.indexOf(col))
        }
      })
    })
  }

  // --- visibility --------------------------------------------------------
  toggle(event) {
    const col = event.target.dataset.col
    if (event.target.checked) this.hidden.delete(col)
    else this.hidden.add(col)
    this.save()
    this.apply()
  }

  // --- reorder (drag headers) -------------------------------------------
  bindDragAndDrop() {
    this.headTargets.forEach((head) => {
      head.addEventListener("dragstart", (e) => {
        this.dragCol = head.dataset.col
        e.dataTransfer.effectAllowed = "move"
      })
      head.addEventListener("dragover", (e) => e.preventDefault())
      head.addEventListener("drop", (e) => {
        e.preventDefault()
        this.moveColumn(this.dragCol, head.dataset.col)
      })
    })
  }

  moveColumn(from, to) {
    if (!from || from === to) return
    const next = this.order.filter((c) => c !== from)
    next.splice(next.indexOf(to), 0, from)
    this.order = next
    this.save()
    this.apply()
  }

  // --- resize (drag the header edge handle) ------------------------------
  startResize(event) {
    event.preventDefault()
    const col = event.target.dataset.col
    const startX = event.clientX
    const startWidth = this.widths[col]

    const onMove = (e) => {
      this.widths[col] = Math.max(60, startWidth + (e.clientX - startX))
      this.apply()
    }
    const onUp = () => {
      document.removeEventListener("mousemove", onMove)
      document.removeEventListener("mouseup", onUp)
      this.save()
    }
    document.addEventListener("mousemove", onMove)
    document.addEventListener("mouseup", onUp)
  }
}
```

- [ ] **Step 4: Run the web test to verify it passes**

Run: `bin/rails test test/integration/targets/index_test.rb`
Expected: PASS.

- [ ] **Step 5: Full suite regression check**

Run: `bin/rails test`
Expected: all green (needs a reachable Postgres `hunter_test`; Mongo is doubled). If Postgres is unavailable in this environment, run at least the Target-scoped tests:
`bin/rails test test/services/targets test/services/simple_icons_test.rb test/models/target_test.rb test/helpers/targets_helper_test.rb test/integration/targets test/integration/api/v1/targets_test.rb`

- [ ] **Step 6: Commit**

```bash
git add app/javascript/controllers/targets_columns_controller.js test/integration/targets/index_test.rb
git commit -m "Add a Stimulus controller for column show/hide, reorder and resize persisted to localStorage"
```

---

### Task 9: Test `Targets::SearchParser`

The service is already written (`app/services/targets/search_parser.rb`) but has
no tests. Lock its contract: free text vs dorks, boolean structure, and the
orphan-operator rule. Because the implementation exists, the tests should pass on
first run — if any fails, fix the service, not the test.

**Files:**
- Test: `web/test/services/targets/search_parser_test.rb`

**Interfaces:**
- Consumes: `Targets::SearchParser.call(String) -> Result(free_text:, expression:)`;
  `Targets::DorkExpression::{Term,And,Or}`.

- [ ] **Step 1: Write the test**

Create `web/test/services/targets/search_parser_test.rb`:

```ruby
require "test_helper"

class Targets::SearchParserTest < ActiveSupport::TestCase
  Term = Targets::DorkExpression::Term
  And_ = Targets::DorkExpression::And
  Or_  = Targets::DorkExpression::Or

  def parse(q) = Targets::SearchParser.call(q)

  test "plain words are free text with no expression" do
    r = parse("cloudron dashboard")
    assert_equal "cloudron dashboard", r.free_text
    assert_nil r.expression
  end

  test "a single dork term parses into a Term with no free text" do
    r = parse("host:example.com")
    assert_equal "", r.free_text
    assert_equal Term.new(key: "host", op: nil, value: "example.com"), r.expression
  end

  test "free text and a dork can mix" do
    r = parse("nginx host:example.com")
    assert_equal "nginx", r.free_text
    assert_equal Term.new(key: "host", op: nil, value: "example.com"), r.expression
  end

  test "adjacent terms imply AND" do
    r = parse("host:a.com status:200")
    assert_equal And_.new(children: [
      Term.new(key: "host", op: nil, value: "a.com"),
      Term.new(key: "status", op: nil, value: "200")
    ]), r.expression
  end

  test "explicit OR builds an Or node" do
    r = parse("status:200 or status:301")
    assert_equal Or_.new(children: [
      Term.new(key: "status", op: nil, value: "200"),
      Term.new(key: "status", op: nil, value: "301")
    ]), r.expression
  end

  test "and/or between non-operands stay free text" do
    r = parse("cats or dogs")
    assert_equal "cats or dogs", r.free_text
    assert_nil r.expression
  end

  test "a range operator is captured on the term" do
    assert_equal Term.new(key: "status", op: ">=", value: "500"), parse("status:>=500").expression
  end

  test "a quoted value keeps its spaces" do
    assert_equal Term.new(key: "title", op: nil, value: "not found"), parse('title:"not found"').expression
  end

  test "an unrecognized key falls through to free text" do
    r = parse("foo:bar")
    assert_equal "foo:bar", r.free_text
    assert_nil r.expression
  end
end
```

- [ ] **Step 2: Run the test**

Run: `bin/rails test test/services/targets/search_parser_test.rb`
Expected: PASS (9 runs, 0 failures). If a case fails, fix `search_parser.rb`.

- [ ] **Step 3: Commit**

```bash
git add test/services/targets/search_parser_test.rb
git commit -m "Test Targets::SearchParser free-text/dork splitting and boolean structure"
```

---

### Task 10: Test `Targets::DorkExpression`

The AST + `Mapper` are already written (`app/services/targets/dork_expression.rb`)
but untested. Lock the per-key Mongo semantics.

**Files:**
- Test: `web/test/services/targets/dork_expression_test.rb`

**Interfaces:**
- Consumes: `Targets::DorkExpression::{Term,And,Or}#to_mongo -> Hash|nil`.

- [ ] **Step 1: Write the test**

Create `web/test/services/targets/dork_expression_test.rb`:

```ruby
require "test_helper"

class Targets::DorkExpressionTest < ActiveSupport::TestCase
  include Targets::DorkExpression

  test "a text key becomes a case-insensitive substring regex" do
    assert_equal(
      { "target.host" => { "$regex" => "example\\.com", "$options" => "i" } },
      Term.new(key: "host", op: nil, value: "example.com").to_mongo
    )
  end

  test "a * in a text value becomes an anchored wildcard" do
    assert_equal(
      { "target.host" => { "$regex" => "\\A.*\\.example\\.com\\z", "$options" => "i" } },
      Term.new(key: "host", op: nil, value: "*.example.com").to_mongo
    )
  end

  test "the tech array field matches any element" do
    assert_equal(
      { "tech" => { "$regex" => "nginx", "$options" => "i" } },
      Term.new(key: "tech", op: nil, value: "nginx").to_mongo
    )
  end

  test "method is an anchored exact match" do
    assert_equal(
      { "target.method" => { "$regex" => "\\AGET\\z", "$options" => "i" } },
      Term.new(key: "method", op: nil, value: "GET").to_mongo
    )
  end

  test "status is numeric equality by default" do
    assert_equal({ "http.status_code" => 200 }, Term.new(key: "status", op: nil, value: "200").to_mongo)
  end

  test "status honors range operators" do
    assert_equal({ "http.status_code" => { "$gte" => 500 } }, Term.new(key: "status", op: ">=", value: "500").to_mongo)
  end

  test "And and Or wrap their children" do
    a = Term.new(key: "status", op: nil, value: "200")
    b = Term.new(key: "host", op: nil, value: "a.com")
    assert_equal({ "$and" => [a.to_mongo, b.to_mongo] }, And.new(children: [a, b]).to_mongo)
    assert_equal({ "$or" => [a.to_mongo, b.to_mongo] }, Or.new(children: [a, b]).to_mongo)
  end

  test "a single-child And collapses to that child" do
    a = Term.new(key: "status", op: nil, value: "200")
    assert_equal a.to_mongo, And.new(children: [a]).to_mongo
  end
end
```

- [ ] **Step 2: Run the test**

Run: `bin/rails test test/services/targets/dork_expression_test.rb`
Expected: PASS (8 runs, 0 failures). If a case fails, fix `dork_expression.rb`.

- [ ] **Step 3: Commit**

```bash
git add test/services/targets/dork_expression_test.rb
git commit -m "Test Targets::DorkExpression per-key Mongo semantics"
```

---

### Task 11: Thread the dork AST through `Targets::MongoSource`

Add an `expression:` keyword to `all`/`count` and combine the mapped filters, the
free-text `$or`, and the dork AST under a single top-level `$and`.

**Files:**
- Modify: `web/app/services/targets/mongo_source.rb`
- Test: `web/test/services/targets/mongo_source_test.rb`

**Interfaces:**
- Consumes: `expression.to_mongo` (Task 10).
- Produces: `Targets::MongoSource.all(filters:, search:, expression:, sort:, dir:, page:, limit:)`
  and `.count(filters:, search:, expression:)`. Consumed by both controllers (Task 12).

- [ ] **Step 1: Add the wiring tests**

Add to `web/test/services/targets/mongo_source_test.rb` (inside the class, after
the existing tests):

```ruby
  test "all applies a dork expression as the sole filter when nothing else is set" do
    collection = FakeCollection.new([])
    expr = Targets::DorkExpression::Term.new(key: "status", op: ">=", value: "500")
    stub_methods(HunterMongo, ensure_indexes_once!: true, collection: collection) do
      Targets::MongoSource.all(expression: expr, limit: 10)
      assert_equal({ "http.status_code" => { "$gte" => 500 } }, collection.last_filter)
    end
  end

  test "all combines free text and a dork expression under $and" do
    collection = FakeCollection.new([])
    expr = Targets::DorkExpression::Term.new(key: "host", op: nil, value: "acme")
    stub_methods(HunterMongo, ensure_indexes_once!: true, collection: collection) do
      Targets::MongoSource.all(search: "nginx", expression: expr, limit: 10)
      clauses = collection.last_filter["$and"]
      assert_equal 2, clauses.length
      assert clauses.any? { |c| c.key?("$or") }
      assert_includes clauses, { "target.host" => { "$regex" => "acme", "$options" => "i" } }
    end
  end

  test "count accepts an expression" do
    collection = Object.new
    captured = nil
    collection.define_singleton_method(:count_documents) { |f| captured = f; 3 }
    expr = Targets::DorkExpression::Term.new(key: "status", op: nil, value: "200")
    stub_methods(HunterMongo, collection: collection) do
      assert_equal 3, Targets::MongoSource.count(expression: expr)
      assert_equal({ "http.status_code" => 200 }, captured)
    end
  end
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run: `bin/rails test test/services/targets/mongo_source_test.rb`
Expected: FAIL — `all`/`count` don't accept `expression:` yet (`ArgumentError: unknown keyword: :expression`).

- [ ] **Step 3: Modify the service**

In `web/app/services/targets/mongo_source.rb`, change the `all` and `count`
signatures and the `build_filter` body:

```ruby
    def all(filters: {}, search: nil, expression: nil, sort: DEFAULT_SORT, dir: "desc", page: 1, limit: 50)
      HunterMongo.ensure_indexes_once!(COLLECTION, INDEXES)
      skip = ([page.to_i, 1].max - 1) * limit
      docs = collection.find(build_filter(filters, search, expression))
                       .sort(sort_spec(sort, dir))
                       .skip(skip)
                       .limit(limit)
                       .to_a
      docs.map { |doc| normalize(doc) }
    rescue Mongo::Error => e
      Rails.logger.warn("Targets::MongoSource#all failed (#{e.class}: #{e.message})")
      []
    end

    def count(filters: {}, search: nil, expression: nil)
      collection.count_documents(build_filter(filters, search, expression))
    rescue Mongo::Error => e
      Rails.logger.warn("Targets::MongoSource#count failed (#{e.class}: #{e.message})")
      0
    end
```

Replace `build_filter` with a clause-collecting version:

```ruby
    # Combine three clause sources — mapped exact filters, the free-text $or, and
    # the dork AST — under one top-level $and. $and is required because the
    # free-text search and an OR dork can each emit a top-level $or, and a Mongo
    # document can hold only one $or key. Collapses to the lone clause (or {}).
    def build_filter(filters, search = nil, expression = nil)
      clauses = []

      filters.to_h.each do |key, value|
        next if value.blank?
        mongo_key = FILTER_KEYS[key.to_s]
        clauses << { mongo_key => value } if mongo_key
      end

      if search.present?
        rx = { "$regex" => Regexp.escape(search.to_s), "$options" => "i" }
        clauses << { "$or" => SEARCH_FIELDS.map { |field| { field => rx } } }
      end

      dork = expression&.to_mongo
      clauses << dork if dork

      case clauses.length
      when 0 then {}
      when 1 then clauses.first
      else { "$and" => clauses }
      end
    end
    private_class_method :build_filter
```

Note: the existing single-filter and single-search tests still pass — one clause
collapses to itself, so `{ "metadata.program" => "acme" }` and the bare
`{ "$or" => [...] }` shapes are unchanged.

- [ ] **Step 4: Run the full service test to verify it passes**

Run: `bin/rails test test/services/targets/mongo_source_test.rb`
Expected: PASS (9 runs, 0 failures — 6 original + 3 new).

- [ ] **Step 5: Commit**

```bash
git add app/services/targets/mongo_source.rb test/services/targets/mongo_source_test.rb
git commit -m "Thread the dork expression through Targets::MongoSource filter building"
```

---

### Task 12: Wire the dork DSL into both controllers

Parse `params[:q]` with `Targets::SearchParser` in the web and API controllers,
keep the raw `q` for the search box, and pass the free text as `search:` plus the
AST as `expression:`.

**Files:**
- Modify: `web/app/controllers/targets_controller.rb`
- Modify: `web/app/controllers/api/v1/targets_controller.rb`
- Test: `web/test/integration/targets/index_test.rb` (update the capture lambda)
- Test: `web/test/integration/api/v1/targets_test.rb` (update the capture lambda)

**Interfaces:**
- Consumes: `Targets::SearchParser.call` (Task 9), `Targets::MongoSource.all/count`
  with `expression:` (Task 11).

- [ ] **Step 1: Update the web integration test**

In `web/test/integration/targets/index_test.rb`, the existing "forwards q, sort
and dir to the source" test's capture lambda must accept the new `expression:`
keyword, and a new test asserts a dork is split out. Replace that test with:

```ruby
  test "forwards q, sort and dir to the source" do
    sign_in_as(@user)
    captured = nil
    capture = ->(filters:, search:, expression:, sort:, dir:, page:, limit:) { captured = { search:, sort:, dir: }; [] }
    stub_methods(Source, all: capture, count: ->(*) { 0 }) do
      get targets_path, params: { q: "nginx", sort: "host", dir: "asc" }
    end
    assert_equal "nginx", captured[:search]
    assert_equal "host", captured[:sort]
    assert_equal "asc", captured[:dir]
  end

  test "splits a dork query into free text and an expression" do
    sign_in_as(@user)
    captured = nil
    capture = ->(filters:, search:, expression:, sort:, dir:, page:, limit:) { captured = { search:, expression: }; [] }
    stub_methods(Source, all: capture, count: ->(*) { 0 }) do
      get targets_path, params: { q: "nginx host:example.com" }
    end
    assert_equal "nginx", captured[:search]
    assert_equal Targets::DorkExpression::Term.new(key: "host", op: nil, value: "example.com"), captured[:expression]
  end
```

- [ ] **Step 2: Update the API integration test**

In `web/test/integration/api/v1/targets_test.rb`, update the "index passes
search, sort and filters through and clamps the limit" test's capture lambda to
accept `expression:`:

```ruby
    capture = ->(filters:, search:, expression:, sort:, dir:, page:, limit:) {
      captured = { filters:, search:, sort:, dir:, page:, limit: }; []
    }
```

(The assertions are unchanged: `q: "nginx"` has no dork, so `search:` is still
`"nginx"`.)

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bin/rails test test/integration/targets/index_test.rb test/integration/api/v1/targets_test.rb`
Expected: FAIL — the controllers don't call `all` with `expression:` yet, so the
capture lambdas raise `ArgumentError: missing keyword: :expression`.

- [ ] **Step 4: Wire the web controller**

In `web/app/controllers/targets_controller.rb`, replace the `index` body's search
setup and the two `MongoSource` calls:

```ruby
  def index
    parsed = Targets::SearchParser.call(params[:q])
    @filters = { "program" => params[:program].presence, "status" => params[:status].presence }.compact
    @search  = params[:q].presence                 # raw text, echoed in the search box
    free     = parsed.free_text.presence
    expr     = parsed.expression
    @sort    = params[:sort].presence || Targets::MongoSource::DEFAULT_SORT
    @dir     = params[:dir] == "asc" ? "asc" : "desc"
    @page    = [params[:page].to_i, 1].max

    docs = Targets::MongoSource.all(
      filters: @filters, search: free, expression: expr, sort: @sort, dir: @dir,
      page: @page, limit: DEFAULT_LIMIT
    )
    @targets = docs.map { |doc| Target.new(doc) }
    @total   = Targets::MongoSource.count(filters: @filters, search: free, expression: expr)
    @next_page_url = (@page * DEFAULT_LIMIT < @total) ?
      targets_path(request.query_parameters.merge("page" => @page + 1)) : nil

    render partial: "targets/rows_page" if request.xhr?
  end
```

- [ ] **Step 5: Wire the API controller**

In `web/app/controllers/api/v1/targets_controller.rb`, replace `index`:

```ruby
      def index
        filters = filter_params
        parsed  = Targets::SearchParser.call(params[:q])
        search  = parsed.free_text.presence
        expr    = parsed.expression
        page    = pagination_page
        limit   = clamped_limit

        docs = Targets::MongoSource.all(
          filters: filters, search: search, expression: expr,
          sort: params[:sort], dir: params[:dir],
          page: page, limit: limit
        )
        render json: {
          count: Targets::MongoSource.count(filters: filters, search: search, expression: expr),
          page: page,
          limit: limit,
          targets: docs.map { |doc| Target.new(doc).as_json }
        }
      end
```

- [ ] **Step 6: Run the integration tests to verify they pass**

Run: `bin/rails test test/integration/targets/index_test.rb test/integration/api/v1/targets_test.rb`
Expected: PASS.

- [ ] **Step 7: Full Target-scoped regression check**

Run: `bin/rails test test/services/targets test/services/simple_icons_test.rb test/models/target_test.rb test/helpers/targets_helper_test.rb test/integration/targets test/integration/api/v1/targets_test.rb`
Expected: all green. (Needs a reachable Postgres `hunter_test`; Mongo is doubled.)

- [ ] **Step 8: Commit**

```bash
git add app/controllers/targets_controller.rb app/controllers/api/v1/targets_controller.rb \
        test/integration/targets/index_test.rb test/integration/api/v1/targets_test.rb
git commit -m "Wire the Target dork search DSL into the web and API controllers"
```

---

## Self-Review Notes (author checklist — already applied)

- **Spec coverage:** module wiring (T5), Target PORO (T4), search/sort/filters (T5/T6/T7), JSON API index+show (T6), sidebar+route+department (T7), default vs toggleable columns (T3 `COLUMNS`, T7 markup), status badge by family (T4/T7), Simple Icons vendored + lookup + monogram fallback + cluster (T1/T2/T3/T7), column show/hide/reorder/resize + localStorage (T8), tests for every unit. Non-goals (toolbar facet chips/actions, AI search, saved views, writes) intentionally omitted.
- **Placeholder scan:** none — every code step is complete.
- **Type consistency:** `Target#verb` (not `method`) used consistently in model, helper, and `target_cell_value`; `SORT_FIELDS`/`DEFAULT_SORT` referenced by both controllers and views are defined in T5.
- **Control Center:** no file under `control_center*` is touched.

### Addendum (2026-07-12) — dork DSL Tasks 9–12

- **Spec coverage:** the "Search — free text + dork DSL" spec section maps to
  T9 (`SearchParser` tests), T10 (`DorkExpression` tests), T11 (`MongoSource`
  `expression:` wiring), T12 (controller wiring). The "Detail side panel" and
  "Infinite scroll" spec sections are already built + tested (see the Status
  block) and need no new task.
- **Placeholder scan:** none — every T9–T12 step carries full test/impl code.
- **Type consistency:** `Targets::SearchParser.call -> Result(free_text:,
  expression:)`; AST nodes `Term.new(key:,op:,value:)` / `And.new(children:)` /
  `Or.new(children:)` with `#to_mongo`. After T11, `MongoSource.all` /
  `count` gain the `expression:` keyword — **all four callers (both controllers
  and both integration capture lambdas) are updated in T11/T12 to match.** The
  existing filter-only and search-only `MongoSource` tests still pass because a
  single clause collapses to itself (no `$and` wrapper).
