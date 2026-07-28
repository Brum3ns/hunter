# Control Center Target Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users select targets (individually or "everything matching the current filter") from the Target page and the Sitemap page and send them as a Control Center job, at a scale of hundreds of thousands of targets, over an API a future MCP can wrap unchanged.

**Architecture:** The browser sends a compact `selections[]` descriptor (a filter query or explicit ids), never the target strings. Each owning module exposes a streaming resolve method (`Targets::MongoSource.each_host`, `Sitemap::EndpointResolver.each_url`); a thin `ControlCenter::TargetSelection` orchestrator unions + de-dups + streams them. Job submission is asynchronous: `create` writes a `queued` Job and returns immediately, and a Solid Queue `ControlCenter::SubmitJob` streams the resolved targets to a temp file and shells out to `whiterabbit standalone -target <file>`.

**Tech Stack:** Ruby 3.3.6, Rails 8, MongoDB (`Mongo` driver) for the `alive` collection, PostgreSQL for the sitemap projection, Solid Queue (ActiveJob), Minitest, Stimulus/Turbo, OpenAPI (`config/openapi/*.yaml`).

## Global Constraints

- Commit author: `Claude <noreply@anthropic.com>`. Commit messages: a single sentence, no body.
- Mirror the Vulnerabilities module pattern: `module_function` service, thin controller `< Api::V1::BaseController`, PORO model.
- Mongo **read** failures swallow `Mongo::Error` and return a safe empty value (`[]`, `0`, `nil`, `false`); **write** paths let it raise (→ `502 upstream_unavailable`).
- Tests: `bin/rails test` from `web/`. Mongo is **doubled** in tests via the `stub_methods(target, mapping) { ... }` helper — no live Mongo. PostgreSQL `hunter_test` must be reachable.
- Per-module API scopes are declared with the `api_scope :<slug>` class macro; wildcard scopes are prohibited. OpenAPI fragment basename == module slug == scope slug.
- No new Assistant context type/tool/provider feature is introduced (the CLAUDE.md "Assistant capability change rule" does not apply to this Control Center work).
- Whiterabbit chunks only when `-target-chunk > 0`; a huge send must never become one message, so a blank/zero chunk is replaced with `CONTROL_CENTER_DEFAULT_TARGET_CHUNK` at submit time.

---

## File Structure

**New files**
- `web/app/services/sitemap/endpoint_resolver.rb` — stream/count endpoint URLs from a selection.
- `web/app/services/control_center/target_selection.rb` — orchestrate count / stream / sample / validate across sources.
- `web/app/jobs/control_center/submit_job.rb` — async: stream targets to a file, run Whiterabbit, finalize the Job.
- `web/app/controllers/api/v1/sitemap/endpoints_controller.rb` — read API for the sitemap endpoint list.
- `web/config/openapi/sitemap.yaml` — OpenAPI fragment for the new sitemap read API.
- `web/db/migrate/<ts>_add_selection_fields_to_control_center_jobs.rb` — Job columns.
- `web/app/javascript/controllers/targets_selection_controller.js` — client selection state, shared by Target + Sitemap pages.
- Test files listed per task.

**Modified files**
- `web/app/services/targets/mongo_source.rb` — add `each_host` / `count_hosts` / `selection_filter`.
- `web/app/controllers/api/v1/targets_controller.rb` — declare `api_scope :targets`.
- `web/app/services/control_center/standalone.rb` — accept a pre-written `target_file:` path.
- `web/app/models/control_center/job.rb` — statuses + new attributes.
- `web/app/controllers/api/v1/control_center/jobs_controller.rb` — `api_scope`, `resolve_targets`, async `create`, idempotency.
- `web/config/routes.rb` — sitemap endpoints route; `resolve_targets` collection route.
- `web/config/openapi/control_center.yaml` — document `resolve_targets`, extended `create`, descriptor schema.
- `web/config/openapi/targets.yaml` — record the `targets` scope.
- `web/app/views/targets/`, `web/app/views/sitemap/`, `web/app/views/control_center/templates/index.html.erb` — selection UI + "Send to job" + dialog preview.
- `web/app/javascript/controllers/control_center_templates_controller.js` — read handoff, preview, post `selections[]`.

---

# Phase 1 — Data resolution, read API, scopes & docs

Backend only, no async, no UI. Produces a complete, scoped, documented selection-and-preview API.

### Task 1: `Targets::MongoSource.each_host` / `count_hosts`

**Files:**
- Modify: `web/app/services/targets/mongo_source.rb`
- Test: `web/test/services/targets/mongo_source_selection_test.rb`

**Interfaces:**
- Consumes: existing `Targets::SearchParser.call(q) -> Result(free_text, expression)`, private `build_filter`, `to_object_id`, `collection`.
- Produces:
  - `Targets::MongoSource.each_host(q: nil, ids: nil, exclude_ids: nil) { |host| }` — yields each matching `target.host` string; returns an `Enumerator` when no block is given; returns `false` and logs on `Mongo::Error`.
  - `Targets::MongoSource.count_hosts(q: nil, ids: nil, exclude_ids: nil) -> Integer` — matching document count (0 on `Mongo::Error`).

- [ ] **Step 1: Write the failing test**

```ruby
# web/test/services/targets/mongo_source_selection_test.rb
require "test_helper"

class Targets::MongoSourceSelectionTest < ActiveSupport::TestCase
  # A fake Mongo collection view: records the filter it was queried with and
  # replays canned docs / count.
  class FakeCollection
    attr_reader :last_filter
    def initialize(docs) = (@docs = docs)
    def find(filter = {})
      @last_filter = filter
      self
    end
    def projection(_spec) = self
    def each(&blk) = @docs.each(&blk)
    def count_documents(filter) = (@last_filter = filter; @docs.size)
  end

  def with_docs(docs)
    fake = FakeCollection.new(docs)
    stub_methods(Targets::MongoSource, collection: fake) { yield fake }
  end

  test "each_host yields target.host for every matching doc" do
    with_docs([{ "target" => { "host" => "a.example.com" } },
               { "target" => { "host" => "b.example.com" } }]) do
      hosts = []
      Targets::MongoSource.each_host { |h| hosts << h }
      assert_equal %w[a.example.com b.example.com], hosts
    end
  end

  test "each_host skips blank hosts and returns an Enumerator without a block" do
    with_docs([{ "target" => { "host" => "" } }, { "target" => { "host" => "c.example.com" } }]) do
      assert_kind_of Enumerator, Targets::MongoSource.each_host
      assert_equal %w[c.example.com], Targets::MongoSource.each_host.to_a
    end
  end

  test "ids build an _id $in filter; exclude_ids build $nin" do
    oid = BSON::ObjectId.new
    with_docs([]) do |fake|
      Targets::MongoSource.each_host(ids: [oid.to_s]) { }
      assert_equal({ "_id" => { "$in" => [oid] } }, fake.last_filter)
    end
    with_docs([]) do |fake|
      Targets::MongoSource.each_host(q: "nginx", exclude_ids: [oid.to_s]) { }
      assert_includes fake.last_filter["$and"], { "_id" => { "$nin" => [oid] } }
    end
  end

  test "count_hosts returns the matching document count" do
    with_docs([{ "target" => { "host" => "a" } }, { "target" => { "host" => "b" } }]) do
      assert_equal 2, Targets::MongoSource.count_hosts(q: "example")
    end
  end

  test "each_host returns false and logs on Mongo::Error" do
    raising = Object.new
    def raising.find(*) = raise(Mongo::Error.new("boom"))
    stub_methods(Targets::MongoSource, collection: raising) do
      assert_equal false, Targets::MongoSource.each_host { }
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bin/rails test test/services/targets/mongo_source_selection_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'each_host'`.

- [ ] **Step 3: Write minimal implementation**

Add to `web/app/services/targets/mongo_source.rb`, inside `module MongoSource` (after `count`):

```ruby
    # Stream the host string of every asset matching a selection. Yields each
    # target.host; returns an Enumerator when called without a block. A Mongo
    # outage logs and returns false (callers must not treat false as "empty").
    def each_host(q: nil, ids: nil, exclude_ids: nil, &block)
      return enum_for(:each_host, q: q, ids: ids, exclude_ids: exclude_ids) unless block
      HunterMongo.ensure_indexes_once!(COLLECTION, INDEXES)
      collection.find(selection_filter(q, ids, exclude_ids))
                .projection("target.host" => 1)
                .each do |doc|
        host = doc.to_h.dig("target", "host") || doc.dig("target", "host")
        block.call(host) if host.to_s.strip.present?
      end
      true
    rescue Mongo::Error => e
      Rails.logger.warn("Targets::MongoSource#each_host failed (#{e.class}: #{e.message})")
      false
    end

    # Count assets matching a selection (one per row, pre-dedup). 0 on outage.
    def count_hosts(q: nil, ids: nil, exclude_ids: nil)
      collection.count_documents(selection_filter(q, ids, exclude_ids))
    rescue Mongo::Error => e
      Rails.logger.warn("Targets::MongoSource#count_hosts failed (#{e.class}: #{e.message})")
      0
    end
```

Add the private filter builder (after `build_filter`):

```ruby
    # A selection is a dork/free-text query plus optional include/exclude ids.
    # Reuses build_filter for the query part and $in/$nin for the id parts,
    # combining under $and (or collapsing to the single clause).
    def selection_filter(q, ids, exclude_ids)
      parsed = SearchParser.call(q)
      query  = build_filter({}, parsed.free_text.presence, parsed.expression)

      clauses = []
      clauses << query unless query.empty?
      oids = Array(ids).filter_map { |i| to_object_id(i) }
      clauses << { "_id" => { "$in" => oids } } if oids.any?
      exs = Array(exclude_ids).filter_map { |i| to_object_id(i) }
      clauses << { "_id" => { "$nin" => exs } } if exs.any?

      case clauses.length
      when 0 then {}
      when 1 then clauses.first
      else { "$and" => clauses }
      end
    end
    private_class_method :selection_filter
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bin/rails test test/services/targets/mongo_source_selection_test.rb`
Expected: PASS (5 assertions/tests green).

- [ ] **Step 5: Commit**

```bash
git add web/app/services/targets/mongo_source.rb web/test/services/targets/mongo_source_selection_test.rb
git commit -m "Add streaming host resolution (each_host/count_hosts) to Targets::MongoSource for job target selection."
```

---

### Task 2: `Sitemap::EndpointResolver`

**Files:**
- Create: `web/app/services/sitemap/endpoint_resolver.rb`
- Test: `web/test/services/sitemap/endpoint_resolver_test.rb`

**Interfaces:**
- Consumes: `Sitemap::Endpoint` (`active` scope, `url` column), `Sitemap::SearchParser.call(q)`, `Sitemap::EndpointFilter.apply(scope, params, free_text:, expression:, include_root:)`.
- Produces:
  - `Sitemap::EndpointResolver.each_url(q: nil, ids: nil, exclude_ids: nil) { |url| }` — yields each matching endpoint `url` (paged with `find_each`); Enumerator without a block.
  - `Sitemap::EndpointResolver.count_urls(q: nil, ids: nil, exclude_ids: nil) -> Integer`.

- [ ] **Step 1: Write the failing test**

```ruby
# web/test/services/sitemap/endpoint_resolver_test.rb
require "test_helper"

class Sitemap::EndpointResolverTest < ActiveSupport::TestCase
  def endpoint(url, **over)
    Sitemap::Endpoint.create!({
      origin: "https://example.com", url: url, path: URI(url).path.presence || "/",
      method: "GET", url_digest: Digest::SHA256.digest("GET\0#{url}")
    }.merge(over))
  end

  test "each_url yields the url of every active endpoint" do
    endpoint("https://example.com/a")
    endpoint("https://example.com/b")
    urls = []
    Sitemap::EndpointResolver.each_url { |u| urls << u }
    assert_equal %w[https://example.com/a https://example.com/b].sort, urls.sort
  end

  test "each_url without a block returns an Enumerator" do
    endpoint("https://example.com/c")
    assert_kind_of Enumerator, Sitemap::EndpointResolver.each_url
    assert_equal %w[https://example.com/c], Sitemap::EndpointResolver.each_url.to_a
  end

  test "ids restrict to the listed rows; exclude_ids remove them" do
    a = endpoint("https://example.com/a")
    b = endpoint("https://example.com/b")
    assert_equal [a.url], Sitemap::EndpointResolver.each_url(ids: [a.id]).to_a
    assert_equal [b.url], Sitemap::EndpointResolver.each_url(exclude_ids: [a.id]).to_a
  end

  test "count_urls counts matching rows" do
    endpoint("https://example.com/a")
    endpoint("https://example.com/b")
    assert_equal 2, Sitemap::EndpointResolver.count_urls
  end

  test "tombstoned (removed_at) endpoints are excluded" do
    endpoint("https://example.com/gone", removed_at: Time.current)
    assert_equal 0, Sitemap::EndpointResolver.count_urls
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bin/rails test test/services/sitemap/endpoint_resolver_test.rb`
Expected: FAIL — uninitialized constant `Sitemap::EndpointResolver`.

- [ ] **Step 3: Write minimal implementation**

```ruby
# web/app/services/sitemap/endpoint_resolver.rb
module Sitemap
  # Streams endpoint URLs for a job-target selection. Reuses the sitemap search
  # parser + endpoint filter so a selection's `q` means exactly what it does on
  # the Sitemap page. Reads from Postgres in batches (find_each) so memory stays
  # flat regardless of the row count.
  module EndpointResolver
    module_function

    def each_url(q: nil, ids: nil, exclude_ids: nil, &block)
      return enum_for(:each_url, q: q, ids: ids, exclude_ids: exclude_ids) unless block
      scope(q, ids, exclude_ids).select(:id, :url).find_each(batch_size: 1_000) do |ep|
        block.call(ep.url) if ep.url.to_s.strip.present?
      end
    end

    def count_urls(q: nil, ids: nil, exclude_ids: nil)
      scope(q, ids, exclude_ids).count
    end

    def scope(q, ids, exclude_ids)
      parsed = Sitemap::SearchParser.call(q)
      s = Sitemap::EndpointFilter.apply(
        Sitemap::Endpoint.active, {},
        free_text: parsed.free_text, expression: parsed.expression
      )
      s = s.where(id: Array(ids)) if ids.present?
      s = s.where.not(id: Array(exclude_ids)) if exclude_ids.present?
      s
    end
    private_class_method :scope
  end
end
```

> Note: `EndpointFilter.apply(scope, {}, …)` must tolerate an empty filter hash (no `path`/`status`/etc.). Confirm by reading `web/app/services/sitemap/endpoint_filter.rb`; the guarded `params[:key]` reads already return nil for a missing key, so `{}` is a no-op filter. If a key is dereferenced unguarded, pass `ActionController::Parameters.new.permit!` instead.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bin/rails test test/services/sitemap/endpoint_resolver_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web/app/services/sitemap/endpoint_resolver.rb web/test/services/sitemap/endpoint_resolver_test.rb
git commit -m "Add Sitemap::EndpointResolver to stream/count endpoint URLs for job target selection."
```

---

### Task 3: `ControlCenter::TargetSelection` orchestrator

**Files:**
- Create: `web/app/services/control_center/target_selection.rb`
- Test: `web/test/services/control_center/target_selection_test.rb`

**Interfaces:**
- Consumes: `Targets::MongoSource.each_host`/`count_hosts`, `Sitemap::EndpointResolver.each_url`/`count_urls`.
- Produces:
  - `TargetSelection.validate!(selections)` — raises `TargetSelection::InvalidSelection` on an unknown/malformed source; returns `true`.
  - `TargetSelection.count(selections, manual_targets = []) -> Integer` — sum of per-source row counts + non-blank manual lines (upper bound; the sent list is de-duped).
  - `TargetSelection.stream(selections, manual_targets = []) { |target| } -> Integer` — yields each unique target string once (manual first, then sources); returns the unique count.
  - `TargetSelection.sample(selections, manual_targets = [], limit: 50) -> Array<String>` — the first `limit` unique targets.

Each selection is a hash-like `{ source: "targets"|"sitemap", mode: "filter"|"ids", q:, ids:, exclude_ids: }`. `mode` is informational; resolution keys off whichever of `q`/`ids`/`exclude_ids` are present.

- [ ] **Step 1: Write the failing test**

```ruby
# web/test/services/control_center/target_selection_test.rb
require "test_helper"

class ControlCenter::TargetSelectionTest < ActiveSupport::TestCase
  Sel = ControlCenter::TargetSelection

  def with_sources(hosts:, urls:)
    stub_methods(Targets::MongoSource,
      each_host: ->(**_) { hosts.each { |h| yield_target(h) } rescue nil },
      count_hosts: ->(**_) { hosts.size }) do
      stub_methods(Sitemap::EndpointResolver,
        each_url: ->(**_) { urls.each { |u| yield_target(u) } rescue nil },
        count_urls: ->(**_) { urls.size }) { yield }
    end
  end

  # each_host/each_url are stubbed to yield via the block they receive; capture it.
  def yield_target(v) = @sink.call(v)

  test "validate! rejects an unknown source" do
    assert_raises(ControlCenter::TargetSelection::InvalidSelection) do
      Sel.validate!([{ "source" => "bogus" }])
    end
    assert Sel.validate!([{ "source" => "targets", "mode" => "filter", "q" => "x" }])
  end

  test "count sums per-source counts plus non-blank manual lines" do
    with_sources(hosts: %w[a b], urls: %w[u1]) do
      count = Sel.count(
        [{ "source" => "targets", "q" => "x" }, { "source" => "sitemap", "q" => "y" }],
        ["m1", "  ", "m2"]
      )
      assert_equal 5, count # 2 hosts + 1 url + 2 manual
    end
  end

  test "stream yields manual first, then sources, de-duped, and returns the unique count" do
    got = []
    @sink = ->(v) { got << v }
    with_sources(hosts: %w[dup.com b.com], urls: %w[https://x/1]) do
      n = Sel.stream(
        [{ "source" => "targets", "q" => "x" }, { "source" => "sitemap", "q" => "y" }],
        ["dup.com", "m1"]
      ) { |v| got_stream(v) }
      assert_equal ["dup.com", "m1", "b.com", "https://x/1"], @streamed
      assert_equal 4, n
    end
  end

  def got_stream(v)
    (@streamed ||= []) << v
  end

  test "sample returns at most `limit` unique targets" do
    @sink = ->(v) {}
    with_sources(hosts: %w[a b c d], urls: []) do
      assert_equal %w[a b], Sel.sample([{ "source" => "targets", "q" => "x" }], [], limit: 2)
    end
  end
end
```

> The stub wiring above threads the yielded values through `@sink`/`got_stream` because `stub_methods` replaces `each_host`/`each_url` with lambdas that must forward to the caller's block. When implementing, keep `each_host`/`each_url` calling their given block so the real orchestrator forwards correctly; the test's indirection only exists because the doubles can't see the private block directly. If this proves awkward, simplify by stubbing the two resolvers to call the block argument directly: `each_host: ->(**){ %w[a b].each { |h| Thread.current[:blk].call(h) } }` — but prefer having the orchestrator pass an explicit block the stub invokes (see Step 3).

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bin/rails test test/services/control_center/target_selection_test.rb`
Expected: FAIL — uninitialized constant `ControlCenter::TargetSelection`.

- [ ] **Step 3: Write minimal implementation**

```ruby
# web/app/services/control_center/target_selection.rb
require "set"

module ControlCenter
  # Turns a client selection descriptor into a target string list by dispatching
  # each entry to the owning module's resolver, then unioning + de-duping. Never
  # queries a data store directly. Streaming keeps memory flat for huge sends.
  module TargetSelection
    module_function

    SOURCES = %w[targets sitemap].freeze

    class InvalidSelection < StandardError; end

    def validate!(selections)
      normalize(selections).each { |sel| source_of(sel) }
      true
    end

    def count(selections, manual_targets = [])
      total = manual_list(manual_targets).size
      normalize(selections).each do |sel|
        args = resolve_args(sel)
        total += case source_of(sel)
                 when "targets" then Targets::MongoSource.count_hosts(**args)
                 when "sitemap" then Sitemap::EndpointResolver.count_urls(**args)
                 end
      end
      total
    end

    def stream(selections, manual_targets = [])
      raise ArgumentError, "block required" unless block_given?
      seen = Set.new
      emit = lambda do |value|
        v = value.to_s.strip
        return if v.empty? || seen.include?(v)
        seen << v
        yield v
      end
      manual_list(manual_targets).each { |t| emit.call(t) }
      normalize(selections).each do |sel|
        args = resolve_args(sel)
        case source_of(sel)
        when "targets" then Targets::MongoSource.each_host(**args) { |h| emit.call(h) }
        when "sitemap" then Sitemap::EndpointResolver.each_url(**args) { |u| emit.call(u) }
        end
      end
      seen.size
    end

    def sample(selections, manual_targets = [], limit: 50)
      out = []
      catch(:done) do
        stream(selections, manual_targets) do |v|
          out << v
          throw :done if out.size >= limit
        end
      end
      out
    end

    # ---- internals ----

    def normalize(selections)
      Array(selections).map do |sel|
        h = sel.respond_to?(:to_unsafe_h) ? sel.to_unsafe_h : sel
        h.to_h.symbolize_keys
      end
    end
    private_class_method :normalize

    def source_of(sel)
      source = sel[:source].to_s
      raise InvalidSelection, "unknown source: #{source.inspect}" unless SOURCES.include?(source)
      source
    end
    private_class_method :source_of

    def resolve_args(sel)
      { q: sel[:q], ids: sel[:ids], exclude_ids: sel[:exclude_ids] }
    end
    private_class_method :resolve_args

    def manual_list(manual_targets)
      Array(manual_targets).map { |t| t.to_s.strip }.reject(&:empty?)
    end
    private_class_method :manual_list
  end
end
```

> With this shape `stream` uses a real block (`yield` inside the `emit` lambda is illegal, so the lambda must forward via the block variable). Adjust: change `stream` to take `&block` and have `emit` call `block.call(v)`:

```ruby
    def stream(selections, manual_targets = [], &block)
      raise ArgumentError, "block required" unless block
      seen = Set.new
      emit = lambda do |value|
        v = value.to_s.strip
        return if v.empty? || seen.include?(v)
        seen << v
        block.call(v)
      end
      manual_list(manual_targets).each { |t| emit.call(t) }
      normalize(selections).each do |sel|
        args = resolve_args(sel)
        case source_of(sel)
        when "targets" then Targets::MongoSource.each_host(**args) { |h| emit.call(h) }
        when "sitemap" then Sitemap::EndpointResolver.each_url(**args) { |u| emit.call(u) }
        end
      end
      seen.size
    end
```

Use this `&block` version; delete the `yield` version above.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bin/rails test test/services/control_center/target_selection_test.rb`
Expected: PASS. (If the stub indirection in the test fights you, rewrite the two source stubs to invoke the block they are handed — the orchestrator passes one explicitly.)

- [ ] **Step 5: Commit**

```bash
git add web/app/services/control_center/target_selection.rb web/test/services/control_center/target_selection_test.rb
git commit -m "Add ControlCenter::TargetSelection to resolve selection descriptors into a de-duped target stream."
```

---

### Task 4: Sitemap read API + `targets` scope + routes

**Files:**
- Create: `web/app/controllers/api/v1/sitemap/endpoints_controller.rb`
- Modify: `web/app/controllers/api/v1/targets_controller.rb` (add `api_scope :targets`)
- Modify: `web/config/routes.rb`
- Test: `web/test/integration/api/v1/sitemap/endpoints_test.rb`
- Test: `web/test/integration/api/v1/targets_scope_test.rb`

**Interfaces:**
- Consumes: `Sitemap::Endpoint`, `Sitemap::EndpointFilter`, `Sitemap::SearchParser`, `pagination_page`, `clamped_limit`.
- Produces: `GET /api/v1/sitemap/endpoints` → `{ endpoints: [{ id, url, path, method, status_code }], page, limit, total }`, scoped `sitemap`.

- [ ] **Step 1: Write the failing tests**

```ruby
# web/test/integration/api/v1/sitemap/endpoints_test.rb
require "test_helper"

class Api::V1::Sitemap::EndpointsTest < ActionDispatch::IntegrationTest
  include SessionTestHelper # provides sign_in / bearer helpers used elsewhere

  def endpoint(url)
    Sitemap::Endpoint.create!(origin: "https://example.com", url: url, path: URI(url).path.presence || "/",
      method: "GET", url_digest: Digest::SHA256.digest("GET\0#{url}"))
  end

  test "index returns a paginated endpoint envelope for a signed-in user" do
    endpoint("https://example.com/a")
    sign_in_as_user
    get "/api/v1/sitemap/endpoints", params: { limit: 10 }
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 1, body["total"]
    assert_equal "https://example.com/a", body["endpoints"].first["url"]
    assert_equal 1, body["page"]
    assert_equal 10, body["limit"]
  end

  test "a bearer token without the sitemap scope is rejected" do
    token = api_token_with_scopes(%w[cves])
    get "/api/v1/sitemap/endpoints", headers: bearer(token)
    assert_response :forbidden
    assert_equal "insufficient_scope", JSON.parse(response.body)["error"]
  end

  test "a bearer token with the sitemap scope is accepted" do
    endpoint("https://example.com/b")
    token = api_token_with_scopes(%w[sitemap])
    get "/api/v1/sitemap/endpoints", headers: bearer(token)
    assert_response :success
  end
end
```

```ruby
# web/test/integration/api/v1/targets_scope_test.rb
require "test_helper"

class Api::V1::TargetsScopeTest < ActionDispatch::IntegrationTest
  include SessionTestHelper

  test "targets index now requires the targets scope for bearer tokens" do
    stub_methods(Targets::MongoSource, all: [], count: 0) do
      token = api_token_with_scopes(%w[cves])
      get "/api/v1/targets", headers: bearer(token)
      assert_response :forbidden

      ok = api_token_with_scopes(%w[targets])
      get "/api/v1/targets", headers: bearer(ok)
      assert_response :success
    end
  end
end
```

> Read `web/test/test_helpers/session_test_helper.rb` for the exact sign-in / bearer helper names (`sign_in_as_user`, `api_token_with_scopes`, `bearer` are placeholders — match whatever the existing `api/v1/*` integration tests use, e.g. `test/integration/api/v1/control_center/jobs_test.rb`). Copy that file's setup verbatim.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd web && bin/rails test test/integration/api/v1/sitemap/endpoints_test.rb test/integration/api/v1/targets_scope_test.rb`
Expected: FAIL — no route for `/api/v1/sitemap/endpoints`; targets does not yet enforce a scope.

- [ ] **Step 3: Write the controller, scope, and routes**

```ruby
# web/app/controllers/api/v1/sitemap/endpoints_controller.rb
module Api
  module V1
    module Sitemap
      # Read-only list of crawled endpoints for target selection. Mirrors the
      # Targets API: paginated envelope, same dork/free-text `q` as the sitemap
      # web page. Read failures degrade to an empty page (never 502 here).
      class EndpointsController < Api::V1::BaseController
        api_scope :sitemap

        def index
          page  = pagination_page
          limit = clamped_limit
          scope = filtered_scope
          total = scope.count
          rows  = scope.order(:id).offset((page - 1) * limit).limit(limit)
          render json: {
            endpoints: rows.map { |e| serialize(e) },
            page: page, limit: limit, total: total
          }
        rescue ActiveRecord::StatementInvalid => e
          Rails.logger.warn("Sitemap endpoints index failed: #{e.message}")
          render json: { endpoints: [], page: page, limit: limit, total: 0 }
        end

        private

        def filtered_scope
          parsed = ::Sitemap::SearchParser.call(params[:q])
          ::Sitemap::EndpointFilter.apply(
            ::Sitemap::Endpoint.active,
            params.permit(:path, :has_query, :content_type, methods: [], status: []),
            free_text: parsed.free_text, expression: parsed.expression
          )
        end

        def serialize(e)
          { id: e.id, url: e.url, path: e.path, method: e.method, status_code: e.status_code }
        end
      end
    end
  end
end
```

Add `api_scope :targets` to `web/app/controllers/api/v1/targets_controller.rb`:

```ruby
    class TargetsController < BaseController
      api_scope :targets

      # GET /api/v1/targets
      def index
```

Add routes in `web/config/routes.rb`. Immediately after the `resources :targets` line (around line 118), add:

```ruby
      # Sitemap module: read-only endpoint list for job target selection.
      namespace :sitemap do
        resources :endpoints, only: %i[index]
      end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd web && bin/rails test test/integration/api/v1/sitemap/endpoints_test.rb test/integration/api/v1/targets_scope_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web/app/controllers/api/v1/sitemap/endpoints_controller.rb web/app/controllers/api/v1/targets_controller.rb web/config/routes.rb web/test/integration/api/v1/sitemap/endpoints_test.rb web/test/integration/api/v1/targets_scope_test.rb
git commit -m "Add scoped /api/v1/sitemap/endpoints read API and declare the targets scope on the targets API."
```

---

### Task 5: OpenAPI fragments for the read surface

**Files:**
- Create: `web/config/openapi/sitemap.yaml`
- Modify: `web/config/openapi/targets.yaml` (mark the `targets` scope)
- Test: `web/test/integration/api/v1/openapi_test.rb` (extend)

**Interfaces:**
- Consumes: `ApiDocs::Spec.document(scopes:)` (merges every `config/openapi/*.yaml` fragment; basename == scope slug; filters by scope).
- Produces: `sitemap.yaml` fragment documenting `GET /api/v1/sitemap/endpoints`.

- [ ] **Step 1: Write the failing test**

Add to `web/test/integration/api/v1/openapi_test.rb` (match the file's existing style):

```ruby
  test "a sitemap-scoped document exposes the endpoints list and hides other modules" do
    doc = ApiDocs::Spec.document(scopes: %w[sitemap])
    assert doc.dig("paths", "/api/v1/sitemap/endpoints", "get"),
           "sitemap endpoints path should be present for a sitemap-scoped token"
    refute doc.dig("paths", "/api/v1/cves"), "cves path should be filtered out"
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bin/rails test test/integration/api/v1/openapi_test.rb`
Expected: FAIL — no `sitemap.yaml` fragment yet, so the path is absent.

- [ ] **Step 3: Write the fragment**

```yaml
# web/config/openapi/sitemap.yaml
paths:
  /api/v1/sitemap/endpoints:
    get:
      tags: ["Sitemap"]
      x-api-scope: sitemap
      summary: "List crawled endpoints"
      description: "Browse the sitemap endpoint inventory (katana ∪ wayback). `q` accepts the same free text + dork expressions as the sitemap page. Used to select job targets."
      parameters:
        - { name: q, in: query, schema: { type: string }, description: "Free-text and/or dork expression (path/status/method/…)." }
        - { name: path, in: query, schema: { type: string } }
        - { name: content_type, in: query, schema: { type: string } }
        - { name: page, in: query, schema: { type: integer, default: 1, minimum: 1 } }
        - { name: limit, in: query, schema: { type: integer, default: 50, maximum: 200 } }
      responses:
        "200":
          description: "Paginated endpoint list."
          content:
            application/json:
              schema:
                allOf:
                  - $ref: "#/components/schemas/PageEnvelope"
                  - type: object
                    properties:
                      endpoints: { type: array, items: { $ref: "#/components/schemas/SitemapEndpoint" } }
        "401": { $ref: "#/components/responses/Unauthorized" }
        "403": { $ref: "#/components/responses/InsufficientScope" }
components:
  schemas:
    SitemapEndpoint:
      type: object
      properties:
        id: { type: integer }
        url: { type: string }
        path: { type: string }
        method: { type: string }
        status_code: { type: integer, nullable: true }
      required: [id, url]
```

In `web/config/openapi/targets.yaml`, add `x-api-scope: targets` under the `get` for both `/api/v1/targets` and `/api/v1/targets/{id}` (so the doc records the newly-enforced scope), e.g.:

```yaml
    get:
      tags: ["Targets"]
      x-api-scope: targets
      summary: "List targets"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bin/rails test test/integration/api/v1/openapi_test.rb`
Expected: PASS. Also confirm the whole doc still builds: `bin/rails runner 'ApiDocs::Spec.document(scopes: nil)'` exits without a `DuplicateKeyError`.

- [ ] **Step 5: Commit**

```bash
git add web/config/openapi/sitemap.yaml web/config/openapi/targets.yaml web/test/integration/api/v1/openapi_test.rb
git commit -m "Document the sitemap endpoints read API and the targets scope in the OpenAPI fragments."
```

---

# Phase 2 — Asynchronous job submission

Turns `create` into an async, streaming, scoped submission with a preview endpoint. Depends on Phase 1.

### Task 6: Job columns + statuses migration & model

**Files:**
- Create: `web/db/migrate/<ts>_add_selection_fields_to_control_center_jobs.rb`
- Modify: `web/app/models/control_center/job.rb`
- Test: `web/test/models/control_center/job_test.rb` (extend)

**Interfaces:**
- Produces: `ControlCenter::Job` gains `selections` (jsonb, default `[]`), `manual_targets` (jsonb, default `[]`), `target_chunk` (int, default 0), `job_delay_ms` (int, default 0), `idempotency_key` (string, unique per `created_by`). `STATUSES` = `%w[queued running succeeded failed pending]`.

> Column named `job_delay_ms` (not `delay`) to avoid any ActiveRecord method-name ambiguity and to make the unit (milliseconds, matching Whiterabbit's `-delay`) explicit.

- [ ] **Step 1: Write the failing test**

Add to `web/test/models/control_center/job_test.rb`:

```ruby
  test "queued and running are valid statuses" do
    %w[queued running succeeded failed].each do |s|
      j = ControlCenter::Job.new(template_name: "t", status: s)
      assert j.valid?, "#{s} should be a valid status"
    end
  end

  test "selections and manual_targets default to empty arrays" do
    j = ControlCenter::Job.create!(template_name: "t", status: "queued", queue_name: "test", target_count: 0)
    assert_equal [], j.selections
    assert_equal [], j.manual_targets
    assert_equal 0, j.target_chunk
    assert_equal 0, j.job_delay_ms
  end

  test "idempotency_key is unique per author" do
    ControlCenter::Job.create!(template_name: "t", status: "queued", queue_name: "test", target_count: 0, created_by: "u", idempotency_key: "k1")
    dup = ControlCenter::Job.new(template_name: "t", status: "queued", queue_name: "test", target_count: 0, created_by: "u", idempotency_key: "k1")
    assert_raises(ActiveRecord::RecordNotUnique) { dup.save!(validate: false) }
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bin/rails test test/models/control_center/job_test.rb`
Expected: FAIL — unknown attribute `selections` / status inclusion rejects `queued`.

- [ ] **Step 3: Write the migration and model change**

```ruby
# web/db/migrate/<ts>_add_selection_fields_to_control_center_jobs.rb
class AddSelectionFieldsToControlCenterJobs < ActiveRecord::Migration[8.0]
  def change
    add_column :control_center_jobs, :selections, :jsonb, null: false, default: []
    add_column :control_center_jobs, :manual_targets, :jsonb, null: false, default: []
    add_column :control_center_jobs, :target_chunk, :integer, null: false, default: 0
    add_column :control_center_jobs, :job_delay_ms, :integer, null: false, default: 0
    add_column :control_center_jobs, :idempotency_key, :string
    add_index :control_center_jobs, %i[created_by idempotency_key],
              unique: true, where: "idempotency_key IS NOT NULL",
              name: "idx_cc_jobs_idempotency"
  end
end
```

```ruby
# web/app/models/control_center/job.rb
module ControlCenter
  class Job < ApplicationRecord
    self.table_name = "control_center_jobs"

    # queued -> running -> succeeded|failed. `pending` retained so historical
    # rows still validate; new submissions start `queued`.
    STATUSES = %w[queued running succeeded failed pending].freeze

    validates :template_name, presence: true
    validates :status, inclusion: { in: STATUSES }
  end
end
```

- [ ] **Step 4: Migrate and run tests**

Run:
```bash
cd web && bin/rails db:migrate && RAILS_ENV=test bin/rails db:migrate
bin/rails test test/models/control_center/job_test.rb
```
Expected: PASS. (If `control_center_jobs.target_count` is `NOT NULL`, new `queued` jobs set `target_count: 0` at create — no schema change needed.)

- [ ] **Step 5: Commit**

```bash
git add web/db/migrate web/db/schema.rb web/app/models/control_center/job.rb web/test/models/control_center/job_test.rb
git commit -m "Add selection/idempotency columns and queued/running statuses to ControlCenter::Job."
```

---

### Task 7: `Standalone.submit` accepts a pre-written target file

**Files:**
- Modify: `web/app/services/control_center/standalone.rb`
- Test: `web/test/services/control_center/standalone_test.rb` (extend or create)

**Interfaces:**
- Produces: `ControlCenter::Standalone.submit(template:, target_file:, queue_name:, target_chunk: 0, delay: 0)` — invokes the binary with the caller-provided `-target <target_file>` path (no longer writes the target list itself).

- [ ] **Step 1: Write the failing test**

```ruby
# web/test/services/control_center/standalone_test.rb
require "test_helper"

class ControlCenter::StandaloneTest < ActiveSupport::TestCase
  Result = Struct.new(:exit_status, :stdout, :stderr, :error, keyword_init: true)

  test "submit passes the caller's target_file path through to the binary flags" do
    template = ControlCenter::Template.new(name: "httpx", commands: [{ "command" => "httpx", "args" => [] }])
    captured = nil
    stub_methods(ControlCenter::TemplateRenderer, to_yaml: "name: httpx\n") do
      stub_methods(ControlCenter::WhiterabbitCommand,
        execute: ->(flags, **_) { captured = flags; Result.new(exit_status: 0, stdout: "ok", stderr: "", error: nil) }) do
        Dir.mktmpdir do |d|
          tf = File.join(d, "targets.txt")
          File.write(tf, "a.com\nb.com\n")
          result = ControlCenter::Standalone.submit(template: template, target_file: tf,
                     queue_name: "test", target_chunk: 100, delay: 0)
          assert_equal 0, result.exit_status
        end
      end
    end
    assert_includes captured, "-target"
    assert_equal captured[captured.index("-target") + 1].then { |p| File.basename(p) }, "targets.txt"
    assert_equal "100", captured[captured.index("-target-chunk") + 1]
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bin/rails test test/services/control_center/standalone_test.rb`
Expected: FAIL — `submit` still expects `targets:` (ArgumentError: unknown keyword `target_file`).

- [ ] **Step 3: Change the signature**

In `web/app/services/control_center/standalone.rb`, replace the `submit` method:

```ruby
    def submit(template:, target_file:, queue_name:, target_chunk: 0, delay: 0)
      Dir.mktmpdir("hunter-cc-") do |dir|
        cmd_dir = File.join(dir, "cmdscript")
        FileUtils.mkdir_p(cmd_dir, mode: 0o700)
        File.write(File.join(cmd_dir, "#{template.name}.yaml"), TemplateRenderer.to_yaml(template))

        nfs_dir = File.join(dir, "nfs")
        FileUtils.mkdir_p(nfs_dir, mode: 0o700)

        flags = [
          "-run", template.name,
          "-folder-cmdscript", cmd_dir,
          "-target", target_file,
          "-queue-name", queue_name.to_s,
          "-target-chunk", target_chunk.to_i.to_s,
          "-delay", delay.to_i.to_s,
          "-folder-nfs", nfs_dir,
          "-db", File.join(dir, "badgerdb")
        ]
        WhiterabbitCommand.execute(flags, timeout: TIMEOUT, max_output: MAX_OUTPUT)
      end
    end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bin/rails test test/services/control_center/standalone_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web/app/services/control_center/standalone.rb web/test/services/control_center/standalone_test.rb
git commit -m "Change ControlCenter::Standalone.submit to accept a pre-written target file path for streaming-scale sends."
```

---

### Task 8: `ControlCenter::SubmitJob`

**Files:**
- Create: `web/app/jobs/control_center/submit_job.rb`
- Test: `web/test/jobs/control_center/submit_job_test.rb`

**Interfaces:**
- Consumes: `ControlCenter::Job`, `ControlCenter::Template`, `ControlCenter::TargetSelection.stream`, `ControlCenter::Standalone.submit(template:, target_file:, queue_name:, target_chunk:, delay:)`.
- Produces: `ControlCenter::SubmitJob.perform_later(job_id)` — sets `running`, streams targets to a temp file (recording `target_count`), applies the default chunk when blank, runs Whiterabbit, finalizes `succeeded`/`failed`.

- [ ] **Step 1: Write the failing test**

```ruby
# web/test/jobs/control_center/submit_job_test.rb
require "test_helper"

class ControlCenter::SubmitJobTest < ActiveSupport::TestCase
  Result = Struct.new(:exit_status, :stdout, :stderr, :error, keyword_init: true)

  def queued_job(**over)
    ControlCenter::Job.create!({ template_name: "httpx", status: "queued", queue_name: "test",
      target_count: 0, selections: [{ "source" => "targets", "q" => "x" }], target_chunk: 0 }.merge(over))
  end

  setup do
    ControlCenter::Template.create!(name: "httpx", commands: [{ "command" => "httpx", "args" => [] }])
  end

  test "streams targets to a file, records the count, and finalizes succeeded" do
    job = queued_job
    captured = {}
    stub_methods(ControlCenter::TargetSelection, stream: ->(sels, manual, &blk) { %w[a.com b.com].each(&blk); 2 }) do
      stub_methods(ControlCenter::Standalone,
        submit: ->(template:, target_file:, queue_name:, target_chunk:, delay:) {
          captured = { file: File.read(target_file), chunk: target_chunk }
          Result.new(exit_status: 0, stdout: "done", stderr: "", error: nil)
        }) do
        ControlCenter::SubmitJob.perform_now(job.id)
      end
    end
    job.reload
    assert_equal "succeeded", job.status
    assert_equal 2, job.target_count
    assert_equal "a.com\nb.com\n", captured[:file]
    assert_equal ControlCenter::SubmitJob::DEFAULT_CHUNK, captured[:chunk] # blank chunk -> default
  end

  test "a non-zero exit finalizes failed with captured stderr" do
    job = queued_job
    stub_methods(ControlCenter::TargetSelection, stream: ->(_s, _m, &blk) { blk.call("a.com"); 1 }) do
      stub_methods(ControlCenter::Standalone,
        submit: ->(**) { Result.new(exit_status: 3, stdout: "", stderr: "nope", error: nil) }) do
        ControlCenter::SubmitJob.perform_now(job.id)
      end
    end
    assert_equal "failed", job.reload.status
    assert_equal "nope", job.stderr
  end

  test "a submitted chunk value is preserved" do
    job = queued_job(target_chunk: 500)
    got = nil
    stub_methods(ControlCenter::TargetSelection, stream: ->(_s, _m, &blk) { blk.call("a"); 1 }) do
      stub_methods(ControlCenter::Standalone, submit: ->(target_chunk:, **) { got = target_chunk; Result.new(exit_status: 0, stdout: "", stderr: "", error: nil) }) do
        ControlCenter::SubmitJob.perform_now(job.id)
      end
    end
    assert_equal 500, got
  end

  test "a missing template fails the job without raising" do
    job = queued_job(template_name: "gone")
    ControlCenter::SubmitJob.perform_now(job.id)
    assert_equal "failed", job.reload.status
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bin/rails test test/jobs/control_center/submit_job_test.rb`
Expected: FAIL — uninitialized constant `ControlCenter::SubmitJob`.

- [ ] **Step 3: Write the job**

```ruby
# web/app/jobs/control_center/submit_job.rb
require "tmpdir"

module ControlCenter
  # Runs one job submission off the request cycle: stream the resolved target
  # list to a temp file, invoke Whiterabbit, and finalize the Job. Memory stays
  # flat regardless of target count because TargetSelection.stream yields.
  class SubmitJob < ApplicationJob
    queue_as :background

    DEFAULT_CHUNK = Integer(ENV.fetch("CONTROL_CENTER_DEFAULT_TARGET_CHUNK", "100"))
    MAX_STDERR = 262_144

    def perform(job_id)
      job = ControlCenter::Job.find_by(id: job_id)
      return unless job && job.status == "queued"

      job.update!(status: "running")
      template = ControlCenter::Template.find_by(name: job.template_name)
      return job.update!(status: "failed", stderr: "template no longer exists") unless template

      Dir.mktmpdir("hunter-cc-targets-") do |dir|
        target_file = File.join(dir, "targets.txt")
        count = 0
        File.open(target_file, "w") do |io|
          ControlCenter::TargetSelection.stream(job.selections, job.manual_targets) do |t|
            io.puts(t)
            count += 1
          end
        end
        job.update!(target_count: count)

        chunk = job.target_chunk.to_i
        chunk = DEFAULT_CHUNK if chunk <= 0

        result = ControlCenter::Standalone.submit(
          template: template, target_file: target_file,
          queue_name: job.queue_name, target_chunk: chunk, delay: job.job_delay_ms.to_i
        )
        finalize(job, result)
      end
    rescue => e
      job&.update(status: "failed", stderr: e.message.to_s.byteslice(0, MAX_STDERR))
      raise
    end

    private

    def finalize(job, result)
      succeeded = result.error.nil? && result.exit_status&.zero?
      job.update!(
        status: succeeded ? "succeeded" : "failed",
        exit_status: result.exit_status,
        stdout: scrub(result.stdout),
        stderr: scrub(result.error || result.stderr)
      )
    end

    def scrub(str)
      str.to_s.dup.force_encoding("UTF-8").scrub
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bin/rails test test/jobs/control_center/submit_job_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web/app/jobs/control_center/submit_job.rb web/test/jobs/control_center/submit_job_test.rb
git commit -m "Add ControlCenter::SubmitJob to stream resolved targets to a file and run Whiterabbit off the request cycle."
```

---

### Task 9: `JobsController` — scope, async `create`, `resolve_targets`, idempotency

**Files:**
- Modify: `web/app/controllers/api/v1/control_center/jobs_controller.rb`
- Modify: `web/config/routes.rb` (add `resolve_targets`)
- Test: `web/test/integration/api/v1/control_center/jobs_test.rb` (extend)

**Interfaces:**
- Consumes: `ControlCenter::TargetSelection.{validate!,count,sample}`, `ControlCenter::SubmitJob.perform_later`, `ControlCenter::Job`, `pagination_page`, `clamped_limit`.
- Produces:
  - `POST /api/v1/control_center/jobs` — writes a `queued` Job (with `selections`, `manual_targets`, `target_chunk`, `job_delay_ms`, optional `idempotency_key`), enqueues `SubmitJob`, returns `201 { …job… }`. A malformed descriptor → `400`. A repeated `idempotency_key` (per author) returns the existing job.
  - `POST /api/v1/control_center/jobs/resolve_targets` — returns `{ count, truncated: false, sample: [<=50] }`; malformed descriptor → `400`.
  - Controller declares `api_scope :control_center`.

- [ ] **Step 1: Write the failing tests**

Add to `web/test/integration/api/v1/control_center/jobs_test.rb` (reuse its existing sign-in helpers):

```ruby
  test "create enqueues SubmitJob and returns a queued job (no inline whiterabbit)" do
    ControlCenter::Template.create!(name: "httpx", commands: [{ "command" => "httpx", "args" => [] }])
    sign_in_as_user
    assert_enqueued_with(job: ControlCenter::SubmitJob) do
      post "/api/v1/control_center/jobs", params: {
        template: "httpx", queue_name: "test", target_chunk: 100,
        selections: [{ source: "targets", mode: "filter", q: "host:*.example.com" }],
        targets: ["manual.example.com"]
      }, as: :json
    end
    assert_response :created
    body = JSON.parse(response.body)
    assert_equal "queued", body["status"]
    job = ControlCenter::Job.find(body["id"])
    assert_equal ["manual.example.com"], job.manual_targets
    assert_equal "targets", job.selections.first["source"]
  end

  test "create with a malformed selection returns 400" do
    ControlCenter::Template.create!(name: "httpx", commands: [{ "command" => "httpx", "args" => [] }])
    sign_in_as_user
    post "/api/v1/control_center/jobs", params: {
      template: "httpx", selections: [{ source: "bogus" }]
    }, as: :json
    assert_response :bad_request
    assert_equal "bad_request", JSON.parse(response.body)["error"]
  end

  test "a repeated idempotency_key returns the existing job without a second enqueue" do
    ControlCenter::Template.create!(name: "httpx", commands: [{ "command" => "httpx", "args" => [] }])
    sign_in_as_user
    payload = { template: "httpx", idempotency_key: "abc", selections: [{ source: "targets", q: "x" }] }
    post "/api/v1/control_center/jobs", params: payload, as: :json
    first_id = JSON.parse(response.body)["id"]
    assert_no_enqueued_jobs(only: ControlCenter::SubmitJob) do
      post "/api/v1/control_center/jobs", params: payload, as: :json
    end
    assert_equal first_id, JSON.parse(response.body)["id"]
  end

  test "resolve_targets returns a count and a bounded sample, not the full list" do
    sign_in_as_user
    stub_methods(ControlCenter::TargetSelection,
      validate!: true, count: 500_000, sample: %w[a.com b.com]) do
      post "/api/v1/control_center/jobs/resolve_targets", params: {
        selections: [{ source: "targets", q: "host:*.example.com" }]
      }, as: :json
    end
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 500_000, body["count"]
    assert_equal false, body["truncated"]
    assert_equal %w[a.com b.com], body["sample"]
  end

  test "control_center scope is enforced for bearer tokens on jobs" do
    token = api_token_with_scopes(%w[cves])
    get "/api/v1/control_center/jobs", headers: bearer(token)
    assert_response :forbidden
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd web && bin/rails test test/integration/api/v1/control_center/jobs_test.rb`
Expected: FAIL — no `resolve_targets` route; `create` still runs inline; no scope enforced.

- [ ] **Step 3: Rewrite the controller and add the route**

Replace the body of `web/app/controllers/api/v1/control_center/jobs_controller.rb`:

```ruby
module Api
  module V1
    module ControlCenter
      # Job history, target-selection preview, and asynchronous submission.
      # create re-validates the template, persists a queued Job (freezing the
      # rendered template + the selection descriptor), and hands off to
      # ControlCenter::SubmitJob. resolve_targets previews the resolved count.
      class JobsController < BaseController
        api_scope :control_center

        def index
          jobs = ::ControlCenter::Job.order(created_at: :desc).limit(clamped_limit)
          render json: { jobs: jobs.map { |j| serialize(j) } }
        end

        def show
          job = ::ControlCenter::Job.find_by(id: params[:id])
          return render_not_found unless job
          render json: serialize(job)
        end

        def resolve_targets
          selections = selection_params
          ::ControlCenter::TargetSelection.validate!(selections)
          manual = manual_targets
          render json: {
            count: ::ControlCenter::TargetSelection.count(selections, manual),
            truncated: false,
            sample: ::ControlCenter::TargetSelection.sample(selections, manual, limit: 50)
          }
        rescue ::ControlCenter::TargetSelection::InvalidSelection => e
          render json: { error: "bad_request", detail: e.message }, status: :bad_request
        end

        def create
          template = ::ControlCenter::Template.find_by(name: params[:template])
          return render_not_found unless template

          errors = ::ControlCenter::TemplateValidator.call(template.commands)
          return render json: { error: "unprocessable_entity", detail: errors }, status: :unprocessable_entity if errors.any?

          selections = selection_params
          ::ControlCenter::TargetSelection.validate!(selections)

          key = params[:idempotency_key].presence
          if key && (existing = ::ControlCenter::Job.find_by(idempotency_key: key, created_by: Current.user&.username))
            return render json: serialize(existing), status: :created
          end

          job = ::ControlCenter::Job.create!(
            template_name: template.name,
            template_snapshot: ::ControlCenter::TemplateRenderer.to_hash(template),
            queue_name: params[:queue_name].presence || "test",
            selections: selections, manual_targets: manual_targets,
            target_chunk: params[:target_chunk].to_i, job_delay_ms: params[:delay].to_i,
            target_count: 0, status: "queued", idempotency_key: key,
            created_by: Current.user&.username
          )
          ::ControlCenter::SubmitJob.perform_later(job.id)
          render json: serialize(job), status: :created
        rescue ::ControlCenter::TargetSelection::InvalidSelection => e
          render json: { error: "bad_request", detail: e.message }, status: :bad_request
        end

        private

        def selection_params
          params.permit(selections: [:source, :mode, :q, { ids: [], exclude_ids: [] }])[:selections] || []
        end

        def manual_targets
          Array(params[:targets]).map { |t| t.to_s.strip }.reject(&:empty?)
        end

        def serialize(j)
          {
            id: j.id, template_name: j.template_name, queue_name: j.queue_name,
            target_count: j.target_count, status: j.status, exit_status: j.exit_status,
            stdout: j.stdout, stderr: j.stderr, created_by: j.created_by, created_at: j.created_at
          }
        end
      end
    end
  end
end
```

Add the `resolve_targets` route in `web/config/routes.rb` — change the jobs line inside `namespace :control_center`:

```ruby
        resources :jobs, only: %i[index show create] do
          post :resolve_targets, on: :collection
        end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd web && bin/rails test test/integration/api/v1/control_center/jobs_test.rb`
Expected: PASS. Also run the whole control_center + targets + sitemap slice:
`bin/rails test test/integration/api/v1 test/services/control_center test/jobs/control_center`

- [ ] **Step 5: Commit**

```bash
git add web/app/controllers/api/v1/control_center/jobs_controller.rb web/config/routes.rb web/test/integration/api/v1/control_center/jobs_test.rb
git commit -m "Make Control Center job create asynchronous and add a scoped resolve_targets preview endpoint."
```

---

### Task 10: OpenAPI for `resolve_targets`, extended `create`, and the descriptor schema

**Files:**
- Modify: `web/config/openapi/control_center.yaml`
- Test: `web/test/integration/api/v1/openapi_test.rb` (extend)

**Interfaces:**
- Produces: OpenAPI paths for `POST /api/v1/control_center/jobs/resolve_targets` and the extended `POST …/jobs`, plus a `CcTargetSelection` component schema (the closed descriptor an MCP maps to a tool input schema).

- [ ] **Step 1: Write the failing test**

```ruby
  test "control_center doc documents resolve_targets and the selection descriptor schema" do
    doc = ApiDocs::Spec.document(scopes: %w[control_center])
    assert doc.dig("paths", "/api/v1/control_center/jobs/resolve_targets", "post")
    schema = doc.dig("components", "schemas", "CcTargetSelection")
    assert_equal %w[targets sitemap], schema.dig("properties", "source", "enum")
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bin/rails test test/integration/api/v1/openapi_test.rb`
Expected: FAIL — path/schema absent.

- [ ] **Step 3: Add to `control_center.yaml`**

Append under `paths:` (matching the file's inline style):

```yaml
  /api/v1/control_center/jobs/resolve_targets:
    post:
      tags: ["Control Center"]
      x-api-scope: control_center
      summary: "Preview the resolved target count for a selection"
      description: "Resolves a selection descriptor to a count (+ small sample) without materializing the full list. Drives the send dialog's 'N targets' summary."
      requestBody:
        required: true
        content: { application/json: { schema: { type: object, properties: { selections: { type: array, items: { $ref: "#/components/schemas/CcTargetSelection" } }, targets: { type: array, items: { type: string } } } } } }
      responses:
        "200":
          description: "Resolved count and a bounded sample."
          content: { application/json: { schema: { type: object, properties: { count: { type: integer }, truncated: { type: boolean }, sample: { type: array, items: { type: string } } }, required: [count, sample] } } }
        "400": { $ref: "#/components/responses/BadRequest" }
        "401": { $ref: "#/components/responses/Unauthorized" }
        "403": { $ref: "#/components/responses/InsufficientScope" }
```

Add (or extend) the `POST /api/v1/control_center/jobs` request body to accept `selections[]`, `idempotency_key`, `target_chunk`, `delay`, `queue_name`, `template`, `targets[]` — if the path already exists in the fragment, extend its `requestBody`; otherwise add it. Add the component schema under `components/schemas`:

```yaml
    CcTargetSelection:
      type: object
      description: "One selection source for a job's target list."
      properties:
        source: { type: string, enum: [targets, sitemap] }
        mode: { type: string, enum: [filter, ids] }
        q: { type: string, description: "Dork/free-text query (filter mode)." }
        ids: { type: array, items: { type: string }, description: "Explicit row ids (ids mode)." }
        exclude_ids: { type: array, items: { type: string }, description: "Rows to drop from a filter selection." }
      required: [source]
```

> If `#/components/responses/BadRequest` does not exist in `base.yaml`, add it there alongside `Unauthorized`/`InsufficientScope`/`NotFound` (shape `{ error: "bad_request" }`). Check `base.yaml` first.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bin/rails test test/integration/api/v1/openapi_test.rb`
Expected: PASS. Confirm the full doc still builds without `DuplicateKeyError`:
`bin/rails runner 'ApiDocs::Spec.document(scopes: nil) && puts("ok")'`

- [ ] **Step 5: Commit**

```bash
git add web/config/openapi/control_center.yaml web/config/openapi/base.yaml web/test/integration/api/v1/openapi_test.rb
git commit -m "Document resolve_targets, async create, and the closed target-selection descriptor schema in OpenAPI."
```

---

# Phase 3 — Web UI

Adds the selection UI, cross-page handoff, and the send-dialog preview. No new server behavior. JS has no unit harness (per the module specs) — each task ends with a manual verification checklist, then a commit.

### Task 11: Shared selection Stimulus controller + Target page selection

**Files:**
- Create: `web/app/javascript/controllers/targets_selection_controller.js`
- Modify: `web/app/views/targets/_toolbar.html.erb`, `web/app/views/targets/_row.html.erb`, `web/app/views/targets/_table.html.erb`
- Modify: `web/app/views/targets/index.html.erb` (wire the controller + a "Send to job" button)

**Interfaces:**
- Produces: a `targets-selection` Stimulus controller that tracks either an explicit id `Set` (ids mode) or "all rows matching the current `q`, minus `exclude_ids`" (filter mode); a **Send to job** action that writes a descriptor to `sessionStorage["hunter.jobSelection"]` and navigates to `/control_center`.

The descriptor written to `sessionStorage`:
```json
{ "selections": [ { "source": "targets", "mode": "filter", "q": "<current q>", "exclude_ids": ["..."] } ] }
```
or, in ids mode:
```json
{ "selections": [ { "source": "targets", "mode": "ids", "ids": ["..."] } ] }
```

- [ ] **Step 1: Write the controller**

```javascript
// web/app/javascript/controllers/targets_selection_controller.js
import { Controller } from "@hotwired/stimulus"

// Tracks a target selection on a list page and hands it to Control Center.
// Two modes: explicit ids, or "all matching the current filter" (with a set of
// un-ticked exclude ids). `source` and the current query come from data attrs
// so the same controller serves the Target page (source=targets) and the
// Sitemap page (source=sitemap).
export default class extends Controller {
  static targets = ["checkbox", "count", "selectAll"]
  static values = { source: String, query: String }

  connect() {
    this.ids = new Set()
    this.excluded = new Set()
    this.allMatching = false
    this.render()
  }

  toggleRow(event) {
    const id = event.target.dataset.id
    if (this.allMatching) {
      event.target.checked ? this.excluded.delete(id) : this.excluded.add(id)
    } else {
      event.target.checked ? this.ids.add(id) : this.ids.delete(id)
    }
    this.render()
  }

  selectAllMatching() {
    this.allMatching = true
    this.excluded.clear()
    this.checkboxTargets.forEach((c) => (c.checked = true))
    this.render()
  }

  clear() {
    this.allMatching = false
    this.ids.clear()
    this.excluded.clear()
    this.checkboxTargets.forEach((c) => (c.checked = false))
    this.render()
  }

  descriptor() {
    if (this.allMatching) {
      return { source: this.sourceValue, mode: "filter", q: this.queryValue,
               exclude_ids: [...this.excluded] }
    }
    return { source: this.sourceValue, mode: "ids", ids: [...this.ids] }
  }

  count() {
    if (this.allMatching) return `all matching − ${this.excluded.size}`
    return `${this.ids.size}`
  }

  sendToJob() {
    const payload = { selections: [this.descriptor()] }
    sessionStorage.setItem("hunter.jobSelection", JSON.stringify(payload))
    window.location.assign("/control_center")
  }

  render() {
    if (this.hasCountTarget) this.countTarget.textContent = this.count()
  }
}
```

- [ ] **Step 2: Wire the views**

- In `_row.html.erb`, add a leading cell with a checkbox carrying the row id:
  ```erb
  <input type="checkbox" data-targets-selection-target="checkbox"
         data-action="targets-selection#toggleRow" data-id="<%= target.id %>">
  ```
- In `_table.html.erb`, add a matching leading header cell (a select-all-on-page checkbox is optional; the "Select all matching filter" button lives in the toolbar).
- In `_toolbar.html.erb`, add the actions:
  ```erb
  <button type="button" data-action="targets-selection#selectAllMatching">Select all matching filter</button>
  <span>Selected: <span data-targets-selection-target="count">0</span></span>
  <button type="button" data-action="targets-selection#sendToJob">Send to job</button>
  ```
- In `index.html.erb`, put `data-controller="targets-selection"` with
  `data-targets-selection-source-value="targets"` and
  `data-targets-selection-query-value="<%= params[:q] %>"` on the element wrapping the toolbar + table.

- [ ] **Step 3: Manual verification**

Run the app (`docker compose up`, ensure the `worker:` process is up). On `/targets`:
- Tick three rows → toolbar shows `Selected: 3`.
- Type a filter, click **Select all matching filter** → count shows "all matching − 0"; untick one row → "all matching − 1".
- Click **Send to job** → lands on `/control_center`; in devtools, `sessionStorage["hunter.jobSelection"]` holds the expected descriptor (filter mode with the current `q` and one `exclude_id`, or ids mode with the ticked ids).

- [ ] **Step 4: Commit**

```bash
git add web/app/javascript/controllers/targets_selection_controller.js web/app/views/targets/
git commit -m "Add target row selection, select-all-by-filter, and Send-to-job handoff on the Target page."
```

---

### Task 12: Sitemap page selection

**Files:**
- Modify: `web/app/views/sitemap/` (the endpoint list partials — the origin tree's endpoint rows) and the sitemap index view.

**Interfaces:**
- Consumes: the same `targets-selection` controller, with `source-value="sitemap"`.

- [ ] **Step 1: Wire the controller into the sitemap endpoint list**

- Put `data-controller="targets-selection"` `data-targets-selection-source-value="sitemap"` `data-targets-selection-query-value="<%= @q %>"` on the sitemap list wrapper.
- Add a checkbox to each endpoint row partial carrying the endpoint id:
  ```erb
  <input type="checkbox" data-targets-selection-target="checkbox"
         data-action="targets-selection#toggleRow" data-id="<%= endpoint.id %>">
  ```
- Add the same toolbar actions (**Select all matching filter**, **Selected: N**, **Send to job**) to the sitemap toolbar.

> The endpoint rows currently render inside the origin tree (`Sitemap::Tree`). If a given row partial doesn't expose an endpoint id, thread `endpoint.id` through the tree node so the checkbox has it. Keep the change minimal — only the leaf endpoint rows are selectable (origins are groupings, not targets).

- [ ] **Step 2: Manual verification**

On `/targets/sitemap`: tick endpoint rows, use **Select all matching filter**, click **Send to job** → `sessionStorage["hunter.jobSelection"]` holds a `source: "sitemap"` descriptor. Lands on `/control_center`.

- [ ] **Step 3: Commit**

```bash
git add web/app/views/sitemap/
git commit -m "Add endpoint selection and Send-to-job handoff on the Sitemap page."
```

---

### Task 13: Send-dialog handoff + preview + submit `selections[]`

**Files:**
- Modify: `web/app/javascript/controllers/control_center_templates_controller.js`
- Modify: `web/app/views/control_center/templates/index.html.erb` (a "N targets" summary line in the send dialog)

**Interfaces:**
- Consumes: `POST /api/v1/control_center/jobs/resolve_targets` and the extended `POST …/jobs`; the `sessionStorage["hunter.jobSelection"]` descriptor.
- Produces: on connect, if a handed-off selection exists, auto-open the send dialog, call `resolve_targets`, show `N targets`; on submit, post `selections[]` + manual `targets[]`.

- [ ] **Step 1: Read the current controller**

Read `web/app/javascript/controllers/control_center_templates_controller.js` for the existing `openSend`, `submitJob`, and target names (`sendTargets`, `sendQueue`, `sendChunk`, `sendDelay`, `jobsUrlValue`). Reuse the existing `apiFetch` helper.

- [ ] **Step 2: Add handoff + preview**

Add to `connect()`:

```javascript
  const stored = sessionStorage.getItem("hunter.jobSelection")
  if (stored) {
    sessionStorage.removeItem("hunter.jobSelection")
    try { this.pendingSelection = JSON.parse(stored) } catch { this.pendingSelection = null }
    if (this.pendingSelection) this.openSendWithSelection()
  }
```

Add methods:

```javascript
  async openSendWithSelection() {
    // Open the dialog against the first template (or prompt the user to pick).
    this.openSend(this.templates?.[0] || this.sendTemplate)
    await this.previewTargets()
  }

  async previewTargets() {
    if (!this.pendingSelection) return
    const body = { ...this.pendingSelection,
      targets: this.sendTargetsTarget.value.split("\n").map((s) => s.trim()).filter(Boolean) }
    const { ok, data } = await apiFetch(this.resolveUrlValue, { method: "POST", body })
    if (ok && this.hasSelectionSummaryTarget) {
      this.selectionSummaryTarget.textContent = `${data.count} targets selected`
    }
  }
```

Extend `submitJob()` to include the pending selection:

```javascript
    const body = {
      template: this.sendTemplate.name,
      targets: this.sendTargetsTarget.value.split("\n").map((s) => s.trim()).filter(Boolean),
      selections: this.pendingSelection ? this.pendingSelection.selections : [],
      queue_name: this.sendQueueTarget.value.trim() || "test",
      target_chunk: Number(this.sendChunkTarget.value) || 0,
      delay: Number(this.sendDelayTarget.value) || 0,
    }
```

Add `static values` entry `resolveUrl: String` and `static targets` entry `selectionSummary`, and in `submitJob`'s success branch keep the existing "link to Jobs tab" behavior (the job is now `queued`).

- [ ] **Step 3: Wire the view**

In `index.html.erb`'s send dialog, add:
```erb
<p data-control-center-templates-target="selectionSummary"></p>
```
and set `data-control-center-templates-resolve-url-value="<%= resolve_targets_api_v1_control_center_jobs_path %>"` on the controller element (verify the route helper name with `bin/rails routes | grep resolve_targets`).

- [ ] **Step 4: Manual verification**

Full path: on `/targets`, select rows → **Send to job** → the Templates page opens the send dialog automatically and shows "N targets selected" (N matches the count for your filter). Pick a template + queue, submit → `201`, the response job is `queued`; the Jobs tab shows it, and once the `worker:` process runs `SubmitJob`, it reaches `succeeded`/`failed` with captured output. Confirm RabbitMQ (`http://localhost:15672`) shows the chunked messages on the queue for a large selection.

- [ ] **Step 5: Commit**

```bash
git add web/app/javascript/controllers/control_center_templates_controller.js web/app/views/control_center/templates/index.html.erb
git commit -m "Wire the send dialog to the handed-off selection: preview the resolved count and submit selections[]."
```

---

### Task 14: Jobs tab shows queued/running

**Files:**
- Modify: `web/app/javascript/controllers/control_center_jobs_controller.js` (status badge map)
- Modify: `web/app/views/control_center/jobs/index.html.erb` if statuses are styled server-side.

**Interfaces:**
- Consumes: the `status` field now includes `queued` and `running`.

- [ ] **Step 1: Add the two statuses to the badge map**

In the jobs controller JS status→class map (emerald for `succeeded`, rose for `failed`), add neutral/amber styles for `queued` and `running` so they render distinctly instead of falling through to an unstyled default.

- [ ] **Step 2: Manual verification**

Submit a job; the Jobs tab shows it as `queued`, then `running`, then `succeeded`/`failed` on refresh, each with a distinct badge.

- [ ] **Step 3: Commit**

```bash
git add web/app/javascript/controllers/control_center_jobs_controller.js web/app/views/control_center/jobs/index.html.erb
git commit -m "Render queued and running Control Center job statuses with distinct badges."
```

---

## Final verification

- [ ] `cd web && bin/rails test` — full suite green.
- [ ] `bin/rails runner 'ApiDocs::Spec.document(scopes: nil) && puts "ok"'` — OpenAPI builds.
- [ ] Manual end-to-end (Task 13 checklist) with the `worker:` process running.
- [ ] `docker-compose*.yaml` documents `CONTROL_CENTER_DEFAULT_TARGET_CHUNK` and notes the `worker:` process must run for jobs to execute (fold into the Task 8 or Task 6 commit if not already present).

## Self-review notes (traceability to the spec)

- Selection descriptor → Tasks 1–3, 9 (contract), 10 (schema).
- Module boundaries (each owns its resolve) → Tasks 1, 2; orchestrator in 3.
- New Sitemap read API → Task 4; docs Task 5.
- Scopes / MCP-readiness → Tasks 4 (sitemap+targets scope), 9 (control_center scope), 5 & 10 (OpenAPI, closed descriptor schema, scope-filtered docs).
- Async execution, streaming, no cap → Tasks 6–8.
- Chunking default → Task 8 (`DEFAULT_CHUNK`).
- Idempotency → Tasks 6 (column), 9 (behavior).
- Preview count-only → Tasks 3 (`count`/`sample`), 9 (`resolve_targets`).
- UI (checkboxes, select-all, handoff, preview, statuses) → Tasks 11–14.
- Governance note (effectful MCP submit needs its own review) → out of code scope; recorded in the spec, not implemented here.
