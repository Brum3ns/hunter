# Hunter Sitemap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Materialize a Postgres relation (`sitemap_targets` + `sitemap_endpoints`) that links katana/wayback endpoint URLs to the alive assets they belong to, kept in sync from MongoDB.

**Architecture:** Postgres is a one-way, rebuildable projection of Mongo (the source of truth). A shared `Sitemap::Applier` performs per-document upsert/tombstone/match; a full-pass `Sitemap::Reconciliation` job (Phase 1) drives it over the whole collections and detects deletes by an epoch stamp; a `Sitemap::StreamWorker` (Phase 2) tails Mongo change streams for low-latency freshness, reusing the same `Applier`, with resume tokens persisted in `mongo_stream_cursors`. Reconciliation stays on as the backstop.

**Tech Stack:** Ruby 3.3.6, Rails 8, PostgreSQL, MongoDB Ruby driver (`mongo` gem) via `HunterMongo`, Solid Queue (recurring jobs), Minitest with the repo's `stub_methods` helper.

## Global Constraints

- Ruby module namespace is `Hunter`; new code lives under `web/`.
- Mongo is authoritative; sync is strictly **Mongo → Postgres, one-way**. Never write projected asset/endpoint data to Postgres from the app outside the sync.
- Mongo **reads swallow `Mongo::Error`** (log + empty/nil); this is the house rule (`Targets::MongoSource`, `Cves::MongoSource`).
- Tests use **no live Mongo** — double `Sitemap::MongoSource` via the `stub_methods` helper in `web/test/test_helper.rb`. Tests need a reachable Postgres `hunter_test`.
- ActiveRecord models for this feature are **namespaced under `Sitemap::`** to avoid colliding with the existing `Target` PORO (`web/app/models/target.rb`).
- Commit author `Claude <noreply@anthropic.com>`; commit messages are a single sentence.
- Migration base class: `ActiveRecord::Migration[8.1]` (matches the most recent create migration).
- Target grain = **origin** (scheme+host+port); matching is **exact origin** after implicit-port normalization; unmatched endpoints go to the **unmatched bucket** (`target_id NULL`); deletes are **soft (tombstone via `removed_at`)**.

### Refinements to the spec (deliberate, within its intent)

- Endpoint provenance is stored as two nullable columns `katana_mongo_id` / `wayback_mongo_id` (instead of a single `source_mongo_id`); the display `source` (`katana`/`wayback`/`both`) is derived from which are present. This makes Phase 2 per-source stream deletes precise.
- `last_seen_at` doubles as the reconciliation **epoch stamp** (no separate `synced_at` column). A row is tombstoned when a full pass does not refresh it.
- Known minor limitation (accepted): in *reconciliation-only* operation, if one of two sources for an endpoint disappears, the `source` field can lag (still say `both`) until a Phase 2 stream delete corrects it. The row itself stays correct (still present in the other source).

---

### Task 1: Migration — the three tables

**Files:**
- Create: `web/db/migrate/20260718000001_create_sitemap_tables.rb`
- Test: `web/test/models/sitemap/schema_test.rb`

**Interfaces:**
- Produces: tables `sitemap_targets`, `sitemap_endpoints`, `mongo_stream_cursors` with the columns/indexes every later task relies on.

- [ ] **Step 1: Write the failing test**

```ruby
# web/test/models/sitemap/schema_test.rb
require "test_helper"

class Sitemap::SchemaTest < ActiveSupport::TestCase
  def conn = ActiveRecord::Base.connection

  test "sitemap tables exist" do
    assert conn.table_exists?(:sitemap_targets)
    assert conn.table_exists?(:sitemap_endpoints)
    assert conn.table_exists?(:mongo_stream_cursors)
  end

  test "endpoints target_id is nullable and cascades" do
    col = conn.columns(:sitemap_endpoints).find { |c| c.name == "target_id" }
    assert col.null, "target_id must be nullable for the unmatched bucket"
  end

  test "origin is unique on targets" do
    idx = conn.indexes(:sitemap_targets).find { |i| i.columns == ["origin"] }
    assert idx&.unique, "targets.origin must be unique"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bin/rails test test/models/sitemap/schema_test.rb`
Expected: FAIL — tables do not exist.

- [ ] **Step 3: Write the migration**

```ruby
# web/db/migrate/20260718000001_create_sitemap_tables.rb
class CreateSitemapTables < ActiveRecord::Migration[8.1]
  def change
    create_table :sitemap_targets do |t|
      t.string   :origin, null: false
      t.string   :scheme, null: false
      t.string   :host,   null: false
      t.integer  :port,   null: false
      t.string   :program
      t.string   :alive_mongo_id
      t.datetime :first_seen_at, null: false
      t.datetime :last_seen_at,  null: false
      t.datetime :removed_at
      t.timestamps
    end
    add_index :sitemap_targets, :origin, unique: true
    add_index :sitemap_targets, :host
    add_index :sitemap_targets, :program
    add_index :sitemap_targets, :removed_at

    create_table :sitemap_endpoints do |t|
      t.references :target, foreign_key: { to_table: :sitemap_targets, on_delete: :cascade }, null: true
      t.string   :origin, null: false
      t.text     :url,    null: false
      t.text     :path,   null: false
      t.string   :method, null: false
      t.string   :source, null: false
      t.integer  :status_code
      t.bigint   :content_length
      t.string   :content_type
      t.binary   :url_digest, null: false
      t.string   :katana_mongo_id
      t.string   :wayback_mongo_id
      t.datetime :first_seen_at, null: false
      t.datetime :last_seen_at,  null: false
      t.datetime :removed_at
      t.timestamps
    end
    add_index :sitemap_endpoints, %i[target_id url_digest], unique: true,
              name: "idx_sitemap_endpoints_matched_digest"
    add_index :sitemap_endpoints, %i[origin url_digest], unique: true,
              where: "target_id IS NULL", name: "idx_sitemap_endpoints_unmatched_digest"
    add_index :sitemap_endpoints, %i[target_id path]
    add_index :sitemap_endpoints, %i[target_id removed_at]
    add_index :sitemap_endpoints, :origin, where: "target_id IS NULL",
              name: "idx_sitemap_endpoints_unmatched_origin"

    create_table :mongo_stream_cursors do |t|
      t.string :collection, null: false
      t.jsonb  :resume_token, null: false, default: {}
      t.timestamps
    end
    add_index :mongo_stream_cursors, :collection, unique: true
  end
end
```

- [ ] **Step 4: Migrate and run the test**

Run: `cd web && bin/rails db:migrate && bin/rails test test/models/sitemap/schema_test.rb`
Expected: PASS (3 tests). `db/schema.rb` is updated.

- [ ] **Step 5: Commit**

```bash
git add web/db/migrate/20260718000001_create_sitemap_tables.rb web/db/schema.rb web/test/models/sitemap/schema_test.rb
git commit -m "Add sitemap_targets, sitemap_endpoints and mongo_stream_cursors tables"
```

---

### Task 2: `Sitemap::Origin` — origin/URL normalization + digest

**Files:**
- Create: `web/app/services/sitemap/origin.rb`
- Test: `web/test/services/sitemap/origin_test.rb`

**Interfaces:**
- Produces:
  - `Sitemap::Origin.build(scheme:, host:, port: nil) -> String | nil` — `"scheme://host:port"`, lowercased, implicit port filled; `nil` if host blank or scheme unknown and no port.
  - `Sitemap::Origin.parse(raw_url) -> Hash | nil` — `{ origin:, scheme:, host:, port:, path:, url: }` for http/https URLs; `url` is normalized (lowercased scheme+host, explicit port via URI default, path kept, query kept, fragment stripped); `nil` on unparseable/non-http.
  - `Sitemap::Origin.digest(url, method) -> String` — binary SHA-256 of `"#{METHOD}\0#{url}"`.

- [ ] **Step 1: Write the failing test**

```ruby
# web/test/services/sitemap/origin_test.rb
require "test_helper"

class Sitemap::OriginTest < ActiveSupport::TestCase
  test "build fills implicit ports and lowercases" do
    assert_equal "https://ex.com:443", Sitemap::Origin.build(scheme: "HTTPS", host: "Ex.com")
    assert_equal "http://ex.com:80",   Sitemap::Origin.build(scheme: "http", host: "ex.com")
    assert_equal "http://ex.com:8080", Sitemap::Origin.build(scheme: "http", host: "ex.com", port: 8080)
  end

  test "build returns nil without a host" do
    assert_nil Sitemap::Origin.build(scheme: "http", host: "")
  end

  test "parse extracts origin, path, and normalized url" do
    r = Sitemap::Origin.parse("HTTPS://Ex.com/Login?a=1#frag")
    assert_equal "https://ex.com:443", r[:origin]
    assert_equal "/Login", r[:path]
    assert_equal "https://ex.com:443/Login?a=1", r[:url]
    assert_equal 443, r[:port]
  end

  test "parse defaults an empty path to slash and rejects non-http" do
    assert_equal "/", Sitemap::Origin.parse("http://ex.com")[:path]
    assert_nil Sitemap::Origin.parse("ftp://ex.com/x")
    assert_nil Sitemap::Origin.parse("not a url")
  end

  test "digest is stable and method-sensitive" do
    a = Sitemap::Origin.digest("https://ex.com:443/x", "get")
    b = Sitemap::Origin.digest("https://ex.com:443/x", "GET")
    c = Sitemap::Origin.digest("https://ex.com:443/x", "POST")
    assert_equal a, b
    assert_equal 32, a.bytesize
    refute_equal a, c
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bin/rails test test/services/sitemap/origin_test.rb`
Expected: FAIL — `uninitialized constant Sitemap::Origin`.

- [ ] **Step 3: Write the implementation**

```ruby
# web/app/services/sitemap/origin.rb
require "uri"
require "digest"

module Sitemap
  # Pure origin/URL normalization shared by the target projection and the
  # endpoint matcher, so both compute an identical origin for the same asset.
  module Origin
    module_function

    DEFAULT_PORTS = { "http" => 80, "https" => 443 }.freeze

    def build(scheme:, host:, port: nil)
      host = host.to_s.strip.downcase
      return nil if host.empty?
      scheme = scheme.to_s.strip.downcase
      port = port.presence&.to_i || DEFAULT_PORTS[scheme]
      return nil unless port
      "#{scheme}://#{host}:#{port}"
    end

    def parse(raw_url)
      uri = URI.parse(raw_url.to_s.strip)
      return nil unless uri.is_a?(URI::HTTP) && uri.host.present?
      scheme = uri.scheme.downcase
      host = uri.host.downcase
      port = uri.port # URI fills the scheme default (80/443) when omitted
      origin = "#{scheme}://#{host}:#{port}"
      path = uri.path.presence || "/"
      url = +"#{origin}#{path}"
      url << "?#{uri.query}" if uri.query.present?
      { origin: origin, scheme: scheme, host: host, port: port, path: path, url: url }
    rescue URI::InvalidURIError
      nil
    end

    def digest(url, method)
      Digest::SHA256.digest("#{method.to_s.upcase}\0#{url}")
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bin/rails test test/services/sitemap/origin_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web/app/services/sitemap/origin.rb web/test/services/sitemap/origin_test.rb
git commit -m "Add Sitemap::Origin for origin, URL and digest normalization"
```

---

### Task 3: `Sitemap::Target` model

**Files:**
- Create: `web/app/models/sitemap/target.rb`
- Test: `web/test/models/sitemap/target_test.rb`

**Interfaces:**
- Consumes: `sitemap_targets` table (Task 1).
- Produces:
  - `Sitemap::Target` with `has_many :endpoints, class_name: "Sitemap::Endpoint"`.
  - scopes `.active` (`removed_at: nil`), `.tombstoned`.
  - `#tombstone!(at)` sets `removed_at`.

- [ ] **Step 1: Write the failing test**

```ruby
# web/test/models/sitemap/target_test.rb
require "test_helper"

class Sitemap::TargetTest < ActiveSupport::TestCase
  def build!(origin: "https://ex.com:443", **over)
    Sitemap::Target.create!({ origin: origin, scheme: "https", host: "ex.com",
      port: 443, first_seen_at: Time.current, last_seen_at: Time.current }.merge(over))
  end

  test "active and tombstoned scopes" do
    live = build!
    dead = build!(origin: "http://ex.com:80", scheme: "http", port: 80, removed_at: Time.current)
    assert_includes Sitemap::Target.active, live
    assert_includes Sitemap::Target.tombstoned, dead
    refute_includes Sitemap::Target.active, dead
  end

  test "tombstone! sets removed_at" do
    t = build!
    t.tombstone!(Time.current)
    assert t.removed_at.present?
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bin/rails test test/models/sitemap/target_test.rb`
Expected: FAIL — `uninitialized constant Sitemap::Target`.

- [ ] **Step 3: Write the model**

```ruby
# web/app/models/sitemap/target.rb
module Sitemap
  # Relational projection of one `alive` asset (one origin). The rich asset
  # detail stays in Mongo (read via Targets::MongoSource); this row owns only
  # the relation. Keyed by the stable natural key `origin`.
  class Target < ApplicationRecord
    self.table_name = "sitemap_targets"

    has_many :endpoints, class_name: "Sitemap::Endpoint",
             foreign_key: :target_id, dependent: :destroy, inverse_of: :target

    scope :active, -> { where(removed_at: nil) }
    scope :tombstoned, -> { where.not(removed_at: nil) }

    def tombstone!(at)
      update!(removed_at: at)
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bin/rails test test/models/sitemap/target_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web/app/models/sitemap/target.rb web/test/models/sitemap/target_test.rb
git commit -m "Add Sitemap::Target relational projection model"
```

---

### Task 4: `Sitemap::Endpoint` model

**Files:**
- Create: `web/app/models/sitemap/endpoint.rb`
- Test: `web/test/models/sitemap/endpoint_test.rb`

**Interfaces:**
- Consumes: `sitemap_endpoints` table (Task 1), `Sitemap::Target` (Task 3).
- Produces:
  - `Sitemap::Endpoint` with `belongs_to :target, optional: true, class_name: "Sitemap::Target"`.
  - scopes `.active`, `.tombstoned`, `.unmatched` (`target_id: nil`).
  - `.derive_source(katana_mongo_id, wayback_mongo_id) -> "katana"|"wayback"|"both"|nil` class method.

- [ ] **Step 1: Write the failing test**

```ruby
# web/test/models/sitemap/endpoint_test.rb
require "test_helper"

class Sitemap::EndpointTest < ActiveSupport::TestCase
  test "derive_source from provenance ids" do
    assert_equal "katana",  Sitemap::Endpoint.derive_source("a", nil)
    assert_equal "wayback", Sitemap::Endpoint.derive_source(nil, "b")
    assert_equal "both",    Sitemap::Endpoint.derive_source("a", "b")
    assert_nil              Sitemap::Endpoint.derive_source(nil, nil)
  end

  test "unmatched scope selects rows with no target" do
    e = Sitemap::Endpoint.create!(origin: "https://ex.com:443", url: "https://ex.com:443/x",
      path: "/x", method: "GET", source: "katana", url_digest: Sitemap::Origin.digest("https://ex.com:443/x", "GET"),
      katana_mongo_id: "a", first_seen_at: Time.current, last_seen_at: Time.current)
    assert_includes Sitemap::Endpoint.unmatched, e
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bin/rails test test/models/sitemap/endpoint_test.rb`
Expected: FAIL — `uninitialized constant Sitemap::Endpoint`.

- [ ] **Step 3: Write the model**

```ruby
# web/app/models/sitemap/endpoint.rb
module Sitemap
  # Projection of a crawled/archived endpoint URL, deduped per target by
  # (target_id, url_digest). `target_id` is nil while unmatched. Provenance is
  # tracked per source so `source` and tombstoning stay precise.
  class Endpoint < ApplicationRecord
    self.table_name = "sitemap_endpoints"

    belongs_to :target, optional: true, class_name: "Sitemap::Target", inverse_of: :endpoints

    scope :active, -> { where(removed_at: nil) }
    scope :tombstoned, -> { where.not(removed_at: nil) }
    scope :unmatched, -> { where(target_id: nil) }

    def self.derive_source(katana_id, wayback_id)
      return "both" if katana_id.present? && wayback_id.present?
      return "katana" if katana_id.present?
      return "wayback" if wayback_id.present?
      nil
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bin/rails test test/models/sitemap/endpoint_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web/app/models/sitemap/endpoint.rb web/test/models/sitemap/endpoint_test.rb
git commit -m "Add Sitemap::Endpoint projection model with per-source provenance"
```

---

### Task 5: Normalizers — alive doc → target attrs, katana/wayback doc → endpoint attrs

**Files:**
- Create: `web/app/services/sitemap/target_normalizer.rb`
- Create: `web/app/services/sitemap/endpoint_normalizer.rb`
- Test: `web/test/services/sitemap/target_normalizer_test.rb`
- Test: `web/test/services/sitemap/endpoint_normalizer_test.rb`

**Interfaces:**
- Consumes: `Sitemap::Origin` (Task 2).
- Produces:
  - `Sitemap::TargetNormalizer.call(alive_doc) -> Hash | nil` — `{ origin:, scheme:, host:, port:, program:, alive_mongo_id: }`.
  - `Sitemap::EndpointNormalizer.call(doc, source:) -> Hash | nil` — `{ origin:, url:, path:, method:, source:, status_code:, content_length:, content_type:, source_mongo_id: }`; `source` is `"katana"` or `"wayback"`.

- [ ] **Step 1: Write the failing tests**

```ruby
# web/test/services/sitemap/target_normalizer_test.rb
require "test_helper"

class Sitemap::TargetNormalizerTest < ActiveSupport::TestCase
  test "maps an alive doc to target attrs" do
    doc = { "_id" => "aid1", "target" => { "scheme" => "https", "host" => "Ex.com", "port" => 443 },
            "metadata" => { "program" => "acme" } }
    r = Sitemap::TargetNormalizer.call(doc)
    assert_equal "https://ex.com:443", r[:origin]
    assert_equal "acme", r[:program]
    assert_equal "aid1", r[:alive_mongo_id]
    assert_equal 443, r[:port]
  end

  test "returns nil when origin cannot be built" do
    assert_nil Sitemap::TargetNormalizer.call({ "target" => { "scheme" => "https" } })
  end
end
```

```ruby
# web/test/services/sitemap/endpoint_normalizer_test.rb
require "test_helper"

class Sitemap::EndpointNormalizerTest < ActiveSupport::TestCase
  test "maps a katana doc" do
    doc = { "_id" => "kid1",
            "request" => { "endpoint" => "https://Ex.com/a?x=1", "method" => "post" },
            "response" => { "status_code" => 200, "content_length" => 12,
                            "headers" => { "Content-Type" => "text/html" } } }
    r = Sitemap::EndpointNormalizer.call(doc, source: "katana")
    assert_equal "https://ex.com:443", r[:origin]
    assert_equal "https://ex.com:443/a?x=1", r[:url]
    assert_equal "/a", r[:path]
    assert_equal "POST", r[:method]
    assert_equal 200, r[:status_code]
    assert_equal "text/html", r[:content_type]
    assert_equal "kid1", r[:source_mongo_id]
    assert_equal "katana", r[:source]
  end

  test "maps a wayback doc with defaults" do
    doc = { "_id" => "wid1", "url" => "http://ex.com/old" }
    r = Sitemap::EndpointNormalizer.call(doc, source: "wayback")
    assert_equal "http://ex.com:80", r[:origin]
    assert_equal "GET", r[:method]
    assert_nil r[:status_code]
    assert_equal "wid1", r[:source_mongo_id]
  end

  test "returns nil on an unparseable url" do
    assert_nil Sitemap::EndpointNormalizer.call({ "url" => "javascript:void(0)" }, source: "wayback")
    assert_nil Sitemap::EndpointNormalizer.call({ "request" => {} }, source: "katana")
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd web && bin/rails test test/services/sitemap/target_normalizer_test.rb test/services/sitemap/endpoint_normalizer_test.rb`
Expected: FAIL — constants undefined.

- [ ] **Step 3: Write the implementations**

```ruby
# web/app/services/sitemap/target_normalizer.rb
module Sitemap
  # Raw `alive` Mongo doc -> target upsert attrs, or nil if no usable origin.
  module TargetNormalizer
    module_function

    def call(doc)
      doc = doc.to_h.transform_keys(&:to_s)
      target = (doc["target"] || {})
      origin = Sitemap::Origin.build(scheme: target["scheme"], host: target["host"], port: target["port"])
      return nil unless origin
      { origin: origin,
        scheme: target["scheme"].to_s.downcase,
        host: target["host"].to_s.downcase,
        port: (target["port"].presence || Sitemap::Origin::DEFAULT_PORTS[target["scheme"].to_s.downcase]).to_i,
        program: (doc["metadata"] || {})["program"],
        alive_mongo_id: doc["_id"]&.to_s }
    end
  end
end
```

```ruby
# web/app/services/sitemap/endpoint_normalizer.rb
module Sitemap
  # Raw katana/wayback Mongo doc -> endpoint upsert attrs, or nil if no usable
  # URL. katana carries request/response detail; wayback is URL-only (GET).
  module EndpointNormalizer
    module_function

    def call(doc, source:)
      doc = doc.to_h.transform_keys(&:to_s)
      raw_url = raw_url_for(doc, source)
      parsed = Sitemap::Origin.parse(raw_url)
      return nil unless parsed

      attrs = { origin: parsed[:origin], url: parsed[:url], path: parsed[:path],
                method: method_for(doc, source), source: source,
                status_code: nil, content_length: nil, content_type: nil,
                source_mongo_id: doc["_id"]&.to_s }

      if source == "katana"
        resp = doc["response"] || {}
        attrs[:status_code]    = resp["status_code"]
        attrs[:content_length] = resp["content_length"]
        attrs[:content_type]   = (resp["headers"] || {})["Content-Type"]
      end
      attrs
    end

    def raw_url_for(doc, source)
      if source == "katana"
        (doc["request"] || {})["endpoint"]
      else
        doc["url"].presence || (doc["request"] || {})["endpoint"]
      end
    end
    private_class_method :raw_url_for

    def method_for(doc, source)
      m = source == "katana" ? (doc["request"] || {})["method"] : nil
      m.presence&.upcase || "GET"
    end
    private_class_method :method_for
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd web && bin/rails test test/services/sitemap/target_normalizer_test.rb test/services/sitemap/endpoint_normalizer_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web/app/services/sitemap/target_normalizer.rb web/app/services/sitemap/endpoint_normalizer.rb web/test/services/sitemap/target_normalizer_test.rb web/test/services/sitemap/endpoint_normalizer_test.rb
git commit -m "Add Sitemap target and endpoint normalizers"
```

> **Note on the wayback URL field:** the normalizer reads `doc["url"]` (falling back to `request.endpoint`). Confirm against a real wayback document; if the field differs, adjust `raw_url_for` only.

---

### Task 6: `Sitemap::MongoSource` — streaming readers + collection wiring

**Files:**
- Create: `web/app/services/sitemap/mongo_source.rb`
- Test: `web/test/services/sitemap/mongo_source_test.rb`

**Interfaces:**
- Consumes: `HunterMongo` (`web/config/initializers/mongo.rb`).
- Produces:
  - Constants `ALIVE`, `KATANA`, `WAYBACK` (collection names from env).
  - `Sitemap::MongoSource.each_alive { |doc| }`, `.each_katana { |doc| }`, `.each_wayback { |doc| }` — stream every doc; swallow `Mongo::Error`.
  - `Sitemap::MongoSource.change_stream(collection, resume_after: nil)` — returns a Mongo change stream (used in Phase 2).

- [ ] **Step 1: Write the failing test**

```ruby
# web/test/services/sitemap/mongo_source_test.rb
require "test_helper"

class Sitemap::MongoSourceTest < ActiveSupport::TestCase
  class FakeCollection
    def initialize(docs) = @docs = docs
    def find = @docs
  end

  test "each_katana yields every doc from the collection" do
    fake = FakeCollection.new([{ "_id" => 1 }, { "_id" => 2 }])
    stub_methods(HunterMongo, collection: ->(name) { assert_equal Sitemap::MongoSource::KATANA, name; fake }) do
      seen = []
      Sitemap::MongoSource.each_katana { |d| seen << d["_id"] }
      assert_equal [1, 2], seen
    end
  end

  test "reads swallow Mongo::Error" do
    stub_methods(HunterMongo, collection: ->(_n) { raise Mongo::Error.new("down") }) do
      assert_nothing_raised { Sitemap::MongoSource.each_alive { |_d| flunk "should not yield" } }
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bin/rails test test/services/sitemap/mongo_source_test.rb`
Expected: FAIL — constant undefined.

- [ ] **Step 3: Write the implementation**

```ruby
# web/app/services/sitemap/mongo_source.rb
module Sitemap
  # Read-only streaming access to the source collections. Reads swallow
  # Mongo::Error (house rule); change_stream lets errors propagate so the worker
  # can back off and resume.
  module MongoSource
    module_function

    ALIVE   = ENV.fetch("MONGO_ALIVE_COLLECTION", "alive")
    KATANA  = ENV.fetch("MONGO_KATANA_COLLECTION", "katana")
    WAYBACK = ENV.fetch("MONGO_WAYBACK_COLLECTION", "wayback")

    def each_alive(&blk)   = each(ALIVE, &blk)
    def each_katana(&blk)  = each(KATANA, &blk)
    def each_wayback(&blk) = each(WAYBACK, &blk)

    def each(collection_name)
      HunterMongo.collection(collection_name).find.each { |doc| yield doc }
    rescue Mongo::Error => e
      Rails.logger.warn("Sitemap::MongoSource#each(#{collection_name}) failed (#{e.class}: #{e.message})")
      nil
    end

    def change_stream(collection_name, resume_after: nil)
      opts = { full_document: "updateLookup" }
      opts[:resume_after] = resume_after if resume_after.present?
      HunterMongo.collection(collection_name).watch([], opts)
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bin/rails test test/services/sitemap/mongo_source_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web/app/services/sitemap/mongo_source.rb web/test/services/sitemap/mongo_source_test.rb
git commit -m "Add Sitemap::MongoSource streaming readers and change_stream helper"
```

---

### Task 7: `Sitemap::Applier` — per-document upsert / tombstone / attach primitives

**Files:**
- Create: `web/app/services/sitemap/applier.rb`
- Test: `web/test/services/sitemap/applier_test.rb`

**Interfaces:**
- Consumes: `Sitemap::Target`, `Sitemap::Endpoint`, `Sitemap::Origin`.
- Produces:
  - `Sitemap::Applier.upsert_target(attrs, now:) -> Sitemap::Target` — upsert by `origin`; refreshes `program`, `alive_mongo_id`, `last_seen_at`, un-tombstones; sets `first_seen_at` on insert.
  - `Sitemap::Applier.upsert_endpoint(attrs, now:) -> Sitemap::Endpoint` — matches an active target by `origin` (else unmatched bucket), upserts by digest, merges per-source provenance, recomputes `source`, un-tombstones.
  - `Sitemap::Applier.attach_orphans_for(target, now:)` — re-links unmatched endpoints whose origin matches `target`, merging into an existing matched row on digest collision.
  - `Sitemap::Applier.tombstone_endpoint_by_source(source, mongo_id, now:)` — clears that source's id; tombstones the row only when no source remains.

- [ ] **Step 1: Write the failing test**

```ruby
# web/test/services/sitemap/applier_test.rb
require "test_helper"

class Sitemap::ApplierTest < ActiveSupport::TestCase
  def now = Time.current

  def katana_attrs(url: "https://ex.com:443/a")
    { origin: "https://ex.com:443", url: url, path: "/a", method: "GET", source: "katana",
      status_code: 200, content_length: nil, content_type: nil, source_mongo_id: "k1" }
  end

  def wayback_attrs(url: "https://ex.com:443/a")
    { origin: "https://ex.com:443", url: url, path: "/a", method: "GET", source: "wayback",
      status_code: nil, content_length: nil, content_type: nil, source_mongo_id: "w1" }
  end

  def target_attrs
    { origin: "https://ex.com:443", scheme: "https", host: "ex.com", port: 443,
      program: "acme", alive_mongo_id: "a1" }
  end

  test "upsert_target inserts then updates by origin, un-tombstoning" do
    t = Sitemap::Applier.upsert_target(target_attrs, now: now)
    t.tombstone!(now)
    t2 = Sitemap::Applier.upsert_target(target_attrs.merge(program: "beta"), now: now)
    assert_equal t.id, t2.id
    assert_nil t2.removed_at
    assert_equal "beta", t2.program
  end

  test "upsert_endpoint matches an active target" do
    Sitemap::Applier.upsert_target(target_attrs, now: now)
    e = Sitemap::Applier.upsert_endpoint(katana_attrs, now: now)
    assert_equal "https://ex.com:443", e.target.origin
    assert_equal "katana", e.source
  end

  test "unmatched endpoint lands in the bucket then attaches when target appears" do
    e = Sitemap::Applier.upsert_endpoint(katana_attrs, now: now)
    assert_nil e.target_id
    t = Sitemap::Applier.upsert_target(target_attrs, now: now)
    Sitemap::Applier.attach_orphans_for(t, now: now)
    assert_equal t.id, e.reload.target_id
  end

  test "katana then wayback for same url converge to source=both" do
    Sitemap::Applier.upsert_target(target_attrs, now: now)
    Sitemap::Applier.upsert_endpoint(katana_attrs, now: now)
    e = Sitemap::Applier.upsert_endpoint(wayback_attrs, now: now)
    assert_equal 1, Sitemap::Endpoint.count
    assert_equal "both", e.source
  end

  test "tombstone_endpoint_by_source only tombstones when no source remains" do
    Sitemap::Applier.upsert_target(target_attrs, now: now)
    Sitemap::Applier.upsert_endpoint(katana_attrs, now: now)
    e = Sitemap::Applier.upsert_endpoint(wayback_attrs, now: now)
    Sitemap::Applier.tombstone_endpoint_by_source("katana", "k1", now: now)
    assert_nil e.reload.removed_at
    assert_equal "wayback", e.source
    Sitemap::Applier.tombstone_endpoint_by_source("wayback", "w1", now: now)
    assert e.reload.removed_at.present?
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bin/rails test test/services/sitemap/applier_test.rb`
Expected: FAIL — constant undefined.

- [ ] **Step 3: Write the implementation**

```ruby
# web/app/services/sitemap/applier.rb
module Sitemap
  # Per-document primitives shared by the reconciliation job (Phase 1) and the
  # change-stream worker (Phase 2). All writes go through here so both paths
  # apply identical matching, merge and tombstone rules.
  module Applier
    module_function

    def upsert_target(attrs, now:)
      t = Sitemap::Target.find_or_initialize_by(origin: attrs[:origin])
      t.first_seen_at ||= now
      t.assign_attributes(
        scheme: attrs[:scheme], host: attrs[:host], port: attrs[:port],
        program: attrs[:program], alive_mongo_id: attrs[:alive_mongo_id],
        last_seen_at: now, removed_at: nil
      )
      t.save!
      t
    end

    def upsert_endpoint(attrs, now:)
      digest = Sitemap::Origin.digest(attrs[:url], attrs[:method])
      target = Sitemap::Target.active.find_by(origin: attrs[:origin])
      ep = find_endpoint(target, attrs[:origin], digest) ||
           Sitemap::Endpoint.new(origin: attrs[:origin], url: attrs[:url], path: attrs[:path],
                                 method: attrs[:method], url_digest: digest, first_seen_at: now)
      ep.target_id = target&.id
      apply_source(ep, attrs, now)
      ep.status_code    = attrs[:status_code]    if attrs[:status_code].present?
      ep.content_length = attrs[:content_length] if attrs[:content_length].present?
      ep.content_type   = attrs[:content_type]   if attrs[:content_type].present?
      ep.last_seen_at = now
      ep.removed_at = nil
      ep.save!
      ep
    end

    def attach_orphans_for(target, now:)
      Sitemap::Endpoint.unmatched.where(origin: target.origin).find_each do |orphan|
        existing = Sitemap::Endpoint.find_by(target_id: target.id, url_digest: orphan.url_digest)
        if existing
          merge_into(existing, orphan, now)
          orphan.destroy!
        else
          orphan.update!(target_id: target.id)
        end
      end
    end

    def tombstone_endpoint_by_source(source, mongo_id, now:)
      col = source == "katana" ? :katana_mongo_id : :wayback_mongo_id
      Sitemap::Endpoint.where(col => mongo_id).find_each do |ep|
        ep.public_send("#{col}=", nil)
        ep.source = Sitemap::Endpoint.derive_source(ep.katana_mongo_id, ep.wayback_mongo_id)
        ep.removed_at = now if ep.source.nil?
        ep.save!
      end
    end

    # --- helpers ---

    def find_endpoint(target, origin, digest)
      if target
        Sitemap::Endpoint.find_by(target_id: target.id, url_digest: digest)
      else
        Sitemap::Endpoint.unmatched.find_by(origin: origin, url_digest: digest)
      end
    end
    private_class_method :find_endpoint

    def apply_source(ep, attrs, _now)
      if attrs[:source] == "katana"
        ep.katana_mongo_id = attrs[:source_mongo_id]
      else
        ep.wayback_mongo_id = attrs[:source_mongo_id]
      end
      ep.source = Sitemap::Endpoint.derive_source(ep.katana_mongo_id, ep.wayback_mongo_id)
    end
    private_class_method :apply_source

    def merge_into(existing, orphan, now)
      existing.katana_mongo_id  ||= orphan.katana_mongo_id
      existing.wayback_mongo_id ||= orphan.wayback_mongo_id
      existing.source = Sitemap::Endpoint.derive_source(existing.katana_mongo_id, existing.wayback_mongo_id)
      existing.last_seen_at = [existing.last_seen_at, orphan.last_seen_at, now].compact.max
      existing.removed_at = nil
      existing.save!
    end
    private_class_method :merge_into
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bin/rails test test/services/sitemap/applier_test.rb`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add web/app/services/sitemap/applier.rb web/test/services/sitemap/applier_test.rb
git commit -m "Add Sitemap::Applier upsert, attach and per-source tombstone primitives"
```

---

### Task 8: `Sitemap::Reconciliation` — full-pass sync + epoch tombstoning

**Files:**
- Create: `web/app/services/sitemap/reconciliation.rb`
- Test: `web/test/services/sitemap/reconciliation_test.rb`

**Interfaces:**
- Consumes: `Sitemap::MongoSource`, `Sitemap::TargetNormalizer`, `Sitemap::EndpointNormalizer`, `Sitemap::Applier`.
- Produces: `Sitemap::Reconciliation.new.run -> Hash` (stats). One full pass: upsert all targets, then all katana + wayback endpoints, tombstone anything not refreshed this run (`last_seen_at < run_at`), and attach orphans for active targets.

- [ ] **Step 1: Write the failing test**

```ruby
# web/test/services/sitemap/reconciliation_test.rb
require "test_helper"

class Sitemap::ReconciliationTest < ActiveSupport::TestCase
  def alive(host) = { "_id" => "a-#{host}", "target" => { "scheme" => "https", "host" => host, "port" => 443 }, "metadata" => { "program" => "acme" } }
  def katana(url) = { "_id" => "k-#{url.hash}", "request" => { "endpoint" => url, "method" => "GET" }, "response" => { "status_code" => 200 } }

  def stub_mongo(alive: [], katana: [], wayback: [])
    stub_methods(Sitemap::MongoSource,
      each_alive:   ->(&b) { alive.each(&b) },
      each_katana:  ->(&b) { katana.each(&b) },
      each_wayback: ->(&b) { wayback.each(&b) }) { yield }
  end

  test "first run materializes matched endpoints" do
    stub_mongo(alive: [alive("ex.com")], katana: [katana("https://ex.com/a")]) do
      stats = Sitemap::Reconciliation.new.run
      assert_equal 1, Sitemap::Target.active.count
      ep = Sitemap::Endpoint.active.sole
      assert_equal "https://ex.com:443", ep.target.origin
      assert_equal 1, stats[:endpoints_upserted]
    end
  end

  test "a URL gone on the next run is tombstoned, and reappearance revives it" do
    stub_mongo(alive: [alive("ex.com")], katana: [katana("https://ex.com/a")]) { Sitemap::Reconciliation.new.run }
    stub_mongo(alive: [alive("ex.com")], katana: []) { Sitemap::Reconciliation.new.run }
    assert Sitemap::Endpoint.sole.removed_at.present?
    stub_mongo(alive: [alive("ex.com")], katana: [katana("https://ex.com/a")]) { Sitemap::Reconciliation.new.run }
    assert_nil Sitemap::Endpoint.sole.removed_at
  end

  test "endpoint seen before its target attaches once the asset appears" do
    stub_mongo(alive: [], katana: [katana("https://ex.com/a")]) { Sitemap::Reconciliation.new.run }
    assert Sitemap::Endpoint.sole.target_id.nil?
    stub_mongo(alive: [alive("ex.com")], katana: [katana("https://ex.com/a")]) { Sitemap::Reconciliation.new.run }
    assert Sitemap::Endpoint.sole.target_id.present?
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bin/rails test test/services/sitemap/reconciliation_test.rb`
Expected: FAIL — constant undefined.

- [ ] **Step 3: Write the implementation**

```ruby
# web/app/services/sitemap/reconciliation.rb
module Sitemap
  # Full-pass Mongo -> Postgres reconciliation: the Phase 1 sync and the
  # permanent backstop for the Phase 2 stream worker. Idempotent and
  # self-healing; safe to run repeatedly. Deletes are detected by an epoch:
  # rows not refreshed this run (last_seen_at < run_at) are tombstoned.
  class Reconciliation
    def run
      run_at = Time.current
      stats = { targets_upserted: 0, endpoints_upserted: 0, targets_tombstoned: 0, endpoints_tombstoned: 0 }

      Sitemap::MongoSource.each_alive do |doc|
        attrs = Sitemap::TargetNormalizer.call(doc) or next
        Sitemap::Applier.upsert_target(attrs, now: run_at)
        stats[:targets_upserted] += 1
      end

      %w[katana wayback].each do |source|
        Sitemap::MongoSource.public_send("each_#{source}") do |doc|
          attrs = Sitemap::EndpointNormalizer.call(doc, source: source) or next
          Sitemap::Applier.upsert_endpoint(attrs, now: run_at)
          stats[:endpoints_upserted] += 1
        end
      end

      stats[:targets_tombstoned] =
        Sitemap::Target.active.where(last_seen_at: ...run_at).update_all(removed_at: run_at)
      stats[:endpoints_tombstoned] =
        Sitemap::Endpoint.active.where(last_seen_at: ...run_at).update_all(removed_at: run_at)

      Sitemap::Target.active.find_each { |t| Sitemap::Applier.attach_orphans_for(t, now: run_at) }

      Rails.logger.info("Sitemap::Reconciliation complete: #{stats.inspect}")
      stats
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bin/rails test test/services/sitemap/reconciliation_test.rb`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add web/app/services/sitemap/reconciliation.rb web/test/services/sitemap/reconciliation_test.rb
git commit -m "Add Sitemap::Reconciliation full-pass sync with epoch tombstoning"
```

---

### Task 9: `Sitemap::SyncJob` + scheduling + collection env wiring

**Files:**
- Create: `web/app/jobs/sitemap/sync_job.rb`
- Modify: `web/config/recurring.yml`
- Modify: `docker-compose.yaml` (web service env — add katana/wayback collection names)
- Test: `web/test/jobs/sitemap/sync_job_test.rb`

**Interfaces:**
- Consumes: `Sitemap::Reconciliation` (Task 8).
- Produces: `Sitemap::SyncJob` (Solid Queue, `queue_as :background`) whose `perform` runs one reconciliation.

- [ ] **Step 1: Write the failing test**

```ruby
# web/test/jobs/sitemap/sync_job_test.rb
require "test_helper"

class Sitemap::SyncJobTest < ActiveSupport::TestCase
  test "perform runs a reconciliation" do
    ran = false
    stub_methods(Sitemap::Reconciliation, new: -> { obj = Object.new; obj.define_singleton_method(:run) { ran = true; {} }; obj }) do
      Sitemap::SyncJob.new.perform
    end
    assert ran, "expected the job to invoke Reconciliation#run"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bin/rails test test/jobs/sitemap/sync_job_test.rb`
Expected: FAIL — constant undefined.

- [ ] **Step 3: Write the job**

```ruby
# web/app/jobs/sitemap/sync_job.rb
module Sitemap
  # Recurring (Solid Queue) full-pass reconciliation of the sitemap projection.
  # Scheduled in config/recurring.yml; also the backstop for the stream worker.
  class SyncJob < ApplicationJob
    queue_as :background

    def perform
      Sitemap::Reconciliation.new.run
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bin/rails test test/jobs/sitemap/sync_job_test.rb`
Expected: PASS.

- [ ] **Step 5: Schedule it and wire collection envs**

Add to `web/config/recurring.yml` under **both** `development:` and `production:` (mirroring `cve_sync`):

```yaml
  sitemap_sync:
    class: Sitemap::SyncJob
    queue: background
    schedule: every 30 minutes
```

Add to the `web` service `environment:` block in `docker-compose.yaml`, next to the existing `MONGO_*` entries:

```yaml
      MONGO_ALIVE_COLLECTION: ${MONGO_ALIVE_COLLECTION:-alive}
      MONGO_KATANA_COLLECTION: ${MONGO_KATANA_COLLECTION:-katana}
      MONGO_WAYBACK_COLLECTION: ${MONGO_WAYBACK_COLLECTION:-wayback}
```

- [ ] **Step 6: Verify the suite still passes and schedule parses**

Run: `cd web && bin/rails test test/jobs/sitemap/ && ruby -ryaml -e "YAML.load_file('config/recurring.yml') and puts 'recurring.yml OK'"`
Expected: PASS + `recurring.yml OK`.

- [ ] **Step 7: Commit**

```bash
git add web/app/jobs/sitemap/sync_job.rb web/config/recurring.yml web/test/jobs/sitemap/sync_job_test.rb docker-compose.yaml
git commit -m "Schedule Sitemap::SyncJob and wire katana/wayback collection envs"
```

> **Phase 1 is now complete and functional end-to-end** — a full-pass reconciliation on a schedule materializes and maintains the sitemap relation. The remaining tasks add near-real-time freshness.

---

### Task 10: `MongoStreamCursor` model — resume-token persistence

**Files:**
- Create: `web/app/models/mongo_stream_cursor.rb`
- Test: `web/test/models/mongo_stream_cursor_test.rb`

**Interfaces:**
- Consumes: `mongo_stream_cursors` table (Task 1).
- Produces:
  - `MongoStreamCursor.token_for(collection) -> Hash | nil` (the stored resume token, or nil).
  - `MongoStreamCursor.save_token(collection, token)` — upsert by collection.

- [ ] **Step 1: Write the failing test**

```ruby
# web/test/models/mongo_stream_cursor_test.rb
require "test_helper"

class MongoStreamCursorTest < ActiveSupport::TestCase
  test "save_token upserts and token_for reads it back" do
    assert_nil MongoStreamCursor.token_for("katana")
    MongoStreamCursor.save_token("katana", { "_data" => "abc" })
    assert_equal({ "_data" => "abc" }, MongoStreamCursor.token_for("katana"))
    MongoStreamCursor.save_token("katana", { "_data" => "def" })
    assert_equal({ "_data" => "def" }, MongoStreamCursor.token_for("katana"))
    assert_equal 1, MongoStreamCursor.where(collection: "katana").count
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bin/rails test test/models/mongo_stream_cursor_test.rb`
Expected: FAIL — constant undefined.

- [ ] **Step 3: Write the model**

```ruby
# web/app/models/mongo_stream_cursor.rb
# Persists the latest MongoDB change-stream resume token per collection so the
# Sitemap stream worker resumes exactly where it left off after a restart.
class MongoStreamCursor < ApplicationRecord
  def self.token_for(collection)
    rec = find_by(collection: collection.to_s)
    rec&.resume_token.presence
  end

  def self.save_token(collection, token)
    rec = find_or_initialize_by(collection: collection.to_s)
    rec.resume_token = token
    rec.save!
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bin/rails test test/models/mongo_stream_cursor_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web/app/models/mongo_stream_cursor.rb web/test/models/mongo_stream_cursor_test.rb
git commit -m "Add MongoStreamCursor for change-stream resume-token persistence"
```

---

### Task 11: `Sitemap::StreamWorker` — apply change events + resume

**Files:**
- Create: `web/app/services/sitemap/stream_worker.rb`
- Test: `web/test/services/sitemap/stream_worker_test.rb`

**Interfaces:**
- Consumes: `Sitemap::MongoSource.change_stream`, `Sitemap::Applier`, the two normalizers, `MongoStreamCursor`.
- Produces:
  - `Sitemap::StreamWorker.new(collection, source:)` where `source` is `nil` for alive, `"katana"`/`"wayback"` for endpoints.
  - `#apply_event(event)` — routes one change-stream event (`insert`/`update`/`replace` → upsert; `delete` → tombstone) and persists the resume token.
  - `#run` — opens the change stream (resuming from the saved token) and applies events until interrupted.

- [ ] **Step 1: Write the failing test**

```ruby
# web/test/services/sitemap/stream_worker_test.rb
require "test_helper"

class Sitemap::StreamWorkerTest < ActiveSupport::TestCase
  def now = Time.current

  def event(op, doc: nil, key: nil, token: { "_data" => "t1" })
    ev = { "operationType" => op, "_id" => token }
    ev["fullDocument"] = doc if doc
    ev["documentKey"] = { "_id" => key } if key
    ev
  end

  test "insert of a katana doc upserts an endpoint and saves the token" do
    Sitemap::Applier.upsert_target({ origin: "https://ex.com:443", scheme: "https", host: "ex.com", port: 443, program: nil, alive_mongo_id: "a1" }, now: now)
    worker = Sitemap::StreamWorker.new(Sitemap::MongoSource::KATANA, source: "katana")
    worker.apply_event(event("insert", doc: { "_id" => "k1", "request" => { "endpoint" => "https://ex.com/a", "method" => "GET" }, "response" => {} }))
    assert_equal 1, Sitemap::Endpoint.active.count
    assert_equal({ "_data" => "t1" }, MongoStreamCursor.token_for(Sitemap::MongoSource::KATANA))
  end

  test "delete of a katana doc tombstones via its source id" do
    Sitemap::Applier.upsert_target({ origin: "https://ex.com:443", scheme: "https", host: "ex.com", port: 443, program: nil, alive_mongo_id: "a1" }, now: now)
    Sitemap::Applier.upsert_endpoint({ origin: "https://ex.com:443", url: "https://ex.com:443/a", path: "/a", method: "GET", source: "katana", source_mongo_id: "k1" }, now: now)
    worker = Sitemap::StreamWorker.new(Sitemap::MongoSource::KATANA, source: "katana")
    worker.apply_event(event("delete", key: "k1"))
    assert Sitemap::Endpoint.sole.removed_at.present?
  end

  test "insert of an alive doc upserts a target and attaches orphans" do
    Sitemap::Applier.upsert_endpoint({ origin: "https://ex.com:443", url: "https://ex.com:443/a", path: "/a", method: "GET", source: "katana", source_mongo_id: "k1" }, now: now)
    worker = Sitemap::StreamWorker.new(Sitemap::MongoSource::ALIVE, source: nil)
    worker.apply_event(event("insert", doc: { "_id" => "a1", "target" => { "scheme" => "https", "host" => "ex.com", "port" => 443 }, "metadata" => {} }))
    assert Sitemap::Endpoint.sole.target_id.present?
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bin/rails test test/services/sitemap/stream_worker_test.rb`
Expected: FAIL — constant undefined.

- [ ] **Step 3: Write the implementation**

```ruby
# web/app/services/sitemap/stream_worker.rb
module Sitemap
  # Tails one collection's MongoDB change stream and applies events to the
  # Postgres projection via Sitemap::Applier, persisting the resume token after
  # each event so it resumes after a restart. `source` is nil for the alive
  # (target) collection, or "katana"/"wayback" for endpoint collections.
  # Reconciliation remains the backstop for anything missed here.
  class StreamWorker
    UPSERT_OPS = %w[insert update replace].freeze

    def initialize(collection, source:)
      @collection = collection
      @source = source
    end

    def run
      loop do
        stream = Sitemap::MongoSource.change_stream(@collection, resume_after: MongoStreamCursor.token_for(@collection))
        stream.each { |event| apply_event(event) }
      rescue Mongo::Error => e
        Rails.logger.warn("Sitemap::StreamWorker(#{@collection}) reconnecting (#{e.class}: #{e.message})")
        sleep 1
      end
    end

    def apply_event(event)
      op = event["operationType"]
      now = Time.current
      if UPSERT_OPS.include?(op)
        apply_upsert(event["fullDocument"], now)
      elsif op == "delete"
        apply_delete(event.dig("documentKey", "_id"), now)
      end
      save_token(event["_id"])
    end

    private

    def apply_upsert(doc, now)
      return unless doc
      if @source.nil?
        attrs = Sitemap::TargetNormalizer.call(doc) or return
        target = Sitemap::Applier.upsert_target(attrs, now: now)
        Sitemap::Applier.attach_orphans_for(target, now: now)
      else
        attrs = Sitemap::EndpointNormalizer.call(doc, source: @source) or return
        Sitemap::Applier.upsert_endpoint(attrs, now: now)
      end
    end

    def apply_delete(mongo_id, now)
      return if mongo_id.blank?
      if @source.nil?
        target = Sitemap::Target.find_by(alive_mongo_id: mongo_id.to_s)
        target&.tombstone!(now)
      else
        Sitemap::Applier.tombstone_endpoint_by_source(@source, mongo_id.to_s, now: now)
      end
    end

    def save_token(token)
      MongoStreamCursor.save_token(@collection, token) if token.present?
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bin/rails test test/services/sitemap/stream_worker_test.rb`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add web/app/services/sitemap/stream_worker.rb web/test/services/sitemap/stream_worker_test.rb
git commit -m "Add Sitemap::StreamWorker to apply change-stream events with resume"
```

---

### Task 12: Worker process wiring — rake task + Procfile

**Files:**
- Create: `web/lib/tasks/sitemap.rake`
- Modify: `web/Procfile.dev`
- Test: `web/test/tasks/sitemap_rake_test.rb`

**Interfaces:**
- Consumes: `Sitemap::StreamWorker` (Task 11).
- Produces: `bin/rails sitemap:stream` — launches a `StreamWorker` per source collection, each in its own thread, and blocks.

- [ ] **Step 1: Write the failing test**

```ruby
# web/test/tasks/sitemap_rake_test.rb
require "test_helper"
require "rake"

class SitemapRakeTest < ActiveSupport::TestCase
  test "sitemap:stream task is defined" do
    Hunter::Application.load_tasks unless Rake::Task.task_defined?("sitemap:stream")
    assert Rake::Task.task_defined?("sitemap:stream")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bin/rails test test/tasks/sitemap_rake_test.rb`
Expected: FAIL — task not defined.

- [ ] **Step 3: Write the rake task**

```ruby
# web/lib/tasks/sitemap.rake
namespace :sitemap do
  desc "Tail MongoDB change streams and apply them to the sitemap projection"
  task stream: :environment do
    sources = {
      Sitemap::MongoSource::ALIVE   => nil,
      Sitemap::MongoSource::KATANA  => "katana",
      Sitemap::MongoSource::WAYBACK => "wayback"
    }
    threads = sources.map do |collection, source|
      Thread.new { Sitemap::StreamWorker.new(collection, source: source).run }
    end
    Rails.logger.info("sitemap:stream watching #{sources.keys.join(', ')}")
    threads.each(&:join)
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bin/rails test test/tasks/sitemap_rake_test.rb`
Expected: PASS.

- [ ] **Step 5: Add the dev process**

Append to `web/Procfile.dev`:

```
stream: bin/rails sitemap:stream
```

(For production, run `bin/rails sitemap:stream` as its own long-lived process alongside the Solid Queue worker — a one-line note for the deploy config, no code here.)

- [ ] **Step 6: Full suite green**

Run: `cd web && bin/rails test test/services/sitemap/ test/models/sitemap/ test/jobs/sitemap/ test/models/mongo_stream_cursor_test.rb test/tasks/sitemap_rake_test.rb`
Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
git add web/lib/tasks/sitemap.rake web/Procfile.dev web/test/tasks/sitemap_rake_test.rb
git commit -m "Add sitemap:stream rake task and dev Procfile entry for the stream worker"
```

---

## Final verification

- [ ] **Run the full sitemap suite**

Run: `cd web && bin/rails test test/services/sitemap/ test/models/sitemap/ test/jobs/sitemap/ test/models/mongo_stream_cursor_test.rb test/tasks/sitemap_rake_test.rb`
Expected: all green, zero failures.

- [ ] **Run the whole suite to confirm no regressions**

Run: `cd web && bin/rails test`
Expected: green.

- [ ] **Live smoke (Docker stack up, run by the user):**
  - `docker compose exec web bin/rails runner "p Sitemap::Reconciliation.new.run"` → prints non-zero stats when alive/katana/wayback have data.
  - `docker compose logs web | grep sitemap:stream` → shows the worker watching the three collections.
  - Insert a katana doc in Mongo, then within a second: `docker compose exec web bin/rails runner "p Sitemap::Endpoint.active.count"` reflects it (change stream path).
