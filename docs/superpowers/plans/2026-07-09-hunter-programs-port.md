# Hunter Programs Module Port — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the Scope web UI program-catalog page into Hunter as a self-contained `Programs::` module (dork search, faceted sidebar, card+table views, program modal, per-user favorites/trash/history), re-skinned to Hunter's monochrome design.

**Architecture:** Mirror Hunter's `Vulnerabilities::` department. Reuse Scope's Ruby service layer (`Query`/`Filter`/`Sort`/`SearchParser`/`DorkExpression`/`ScopeType`/`Source`) and Stimulus controllers near-verbatim, swapping Scope's single-collection `ScopeMongo` for a `Programs::MongoSource` wrapper over Hunter's collection-agnostic `HunterMongo`. Re-skin every view from Scope's custom Tailwind theme to Hunter's zinc palette + `heroicon`.

**Tech Stack:** Ruby 3.3.6, Rails 8.1, MongoDB (`mongo` gem, via `HunterMongo`), PostgreSQL, Tailwind v4, importmap + Stimulus/Turbo, Minitest.

## Global Constraints

- **Namespace isolation:** all new Ruby under `Programs::` (controllers `app/controllers/programs/`, services `app/services/programs/`); no changes to `Vulnerabilities::` code. New JS files live in `app/javascript/controllers/` (flat dir, auto-registered).
- **Source of truth for ported code:** the Scope checkout at `tmp/scope/web/`. "Copy" steps copy from there.
- **Design language:** Hunter monochrome zinc — **no color accent**. Apply this token map to every ported view and to JS class-toggles:
  | Scope | Hunter |
  |---|---|
  | `bg-bg` / `bg-surface` / `bg-surface/80` etc. | `bg-white dark:bg-[#111315]` |
  | `border-edge` (+ `/40`,`/60`) | `border-zinc-200 dark:border-zinc-800` |
  | `text-text` | `text-zinc-900 dark:text-zinc-100` |
  | `text-text-soft` | `text-zinc-600 dark:text-zinc-400` |
  | `text-text-dim` | `text-zinc-500 dark:text-zinc-400` |
  | `text-brand` / `bg-brand/10` / `border-brand/40` / brand glow/ring | `text-zinc-900 dark:text-white` / `bg-zinc-100 dark:bg-white/10` / `border-zinc-300 dark:border-zinc-700` / (drop glow & ring) |
  | `text-gold` (active star) | `text-zinc-900 dark:text-white` |
  | `text-red-500` + red glow (active trash) | `text-zinc-900 dark:text-white` (no glow) |
  | `pf-*` platform colors, `pf-banner-*`, bundled logos | dropped — neutral zinc badge/text |
- **Icons:** replace Scope `icon "name", ...` with Hunter `heroicon "name", classes: "h-4 w-4"`. Icon-name map (Scope → heroicon key added in Task 5): `search→magnifying-glass`, `star→star`, `grid→squares-2x2`, `list→list-bullet`, `arrow-up→arrow-up`, `arrow-down→arrow-down`, `help-circle→question-mark-circle` (exists), `x→x-mark` (exists), `trash→trash`, `clock→clock`, `chevron-down→chevron-down` (exists), `external-link→arrow-top-right-on-square`, `download→arrow-down-tray`, `copy→clipboard`.
- **Commit style:** author `Claude <noreply@anthropic.com>`; one-sentence messages. Use `git -c user.name=Claude -c user.email=noreply@anthropic.com commit`.
- **Tests:** run from `web/`. Mongo is doubled (`stub_methods` in `test/test_helper.rb`); Postgres `hunter_test` must be reachable. Never require live Mongo.
- **No new gems**; no external JS (no DOMPurify — policy HTML sanitized server-side with Rails `sanitize`).

---

### Task 1: `Programs::MongoSource` (collection wrapper + indexes)

**Files:**
- Create: `web/app/services/programs/mongo_source.rb`
- Test: `web/test/services/programs/mongo_source_test.rb`

**Interfaces:**
- Produces: `Programs::MongoSource.collection` → Mongo collection handle for `"programs"`; `Programs::MongoSource.ensure_indexes_once!` → idempotent index creation; `Programs::MongoSource.healthy?` → Boolean; constants `COLLECTION = "programs"`, `INDEXES` (array).

- [ ] **Step 1: Write the failing test**

```ruby
# web/test/services/programs/mongo_source_test.rb
require "test_helper"

class Programs::MongoSourceTest < ActiveSupport::TestCase
  test "COLLECTION is programs" do
    assert_equal "programs", Programs::MongoSource::COLLECTION
  end

  test "collection delegates to HunterMongo with the programs name" do
    fake = Object.new
    stub_methods(HunterMongo, collection: ->(name) { name == "programs" ? fake : nil }) do
      assert_same fake, Programs::MongoSource.collection
    end
  end

  test "ensure_indexes_once! passes COLLECTION and INDEXES to HunterMongo" do
    seen = nil
    stub_methods(HunterMongo, ensure_indexes_once!: ->(name, idx) { seen = [name, idx]; true }) do
      assert Programs::MongoSource.ensure_indexes_once!
    end
    assert_equal ["programs", Programs::MongoSource::INDEXES], seen
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bin/rails test test/services/programs/mongo_source_test.rb`
Expected: FAIL — `uninitialized constant Programs::MongoSource`.

- [ ] **Step 3: Write the implementation**

```ruby
# web/app/services/programs/mongo_source.rb
module Programs
  # Read/index wiring for the `programs` MongoDB collection (populated by the
  # Scope Go CLI, keyed on `_sid`). Thin wrapper over the collection-agnostic
  # HunterMongo so the ported Query/Source services only reference this module.
  module MongoSource
    module_function

    COLLECTION = ENV.fetch("MONGO_PROGRAMS_COLLECTION", "programs")

    # Field names track the JSON keys scope emits (some TitleCase upstream, e.g.
    # the report-bucket counters — mirrored verbatim so sorts/filters hit them).
    INDEXES = [
      { key: { _sid: 1 },                          unique: true, name: "sid_unique" },
      { key: { platform: 1 },                                    name: "platform" },
      { key: { public: 1 },                                      name: "public" },
      { key: { bounty: 1 },                                      name: "bounty" },
      { key: { vdp: 1 },                                         name: "vdp" },
      { key: { collaboration: 1 },                               name: "collaboration" },
      { key: { bounty_min: -1 },                                 name: "bounty_min" },
      { key: { bounty_max: -1 },                                 name: "bounty_max" },
      { key: { reward_avg: -1 },                                 name: "reward_avg" },
      { key: { reward_max: -1 },                                 name: "reward_max" },
      { key: { report_count: -1 },                               name: "report_count" },
      { key: { Total_reports_last24_hours: -1 },                 name: "reports_24h" },
      { key: { Total_reports_last7_days: -1 },                   name: "reports_7d" },
      { key: { Total_reports_current_month: -1 },                name: "reports_month" },
      { key: { Average_first_time_response: 1 },                 name: "response_time" },
      { key: { scope_count: -1 },                                name: "scope_count" },
      { key: { updated_at: -1 },                                 name: "updated_at" },
      { key: { name: 1 },                                        name: "name" },
      { key: { "scope.type": 1 },                                name: "scope_type" }
    ].freeze

    def collection             = HunterMongo.collection(COLLECTION)
    def ensure_indexes_once!   = HunterMongo.ensure_indexes_once!(COLLECTION, INDEXES)
    def healthy?               = HunterMongo.healthy?
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bin/rails test test/services/programs/mongo_source_test.rb`
Expected: PASS (3 runs, 0 failures).

- [ ] **Step 5: Commit**

```bash
git -c user.name=Claude -c user.email=noreply@anthropic.com add web/app/services/programs/mongo_source.rb web/test/services/programs/mongo_source_test.rb
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Add Programs::MongoSource wrapping the programs collection over HunterMongo"
```

---

### Task 2: `Program` model + `ScopeType` service

**Files:**
- Create: `web/app/models/program.rb` (copy of `tmp/scope/web/app/models/program.rb`, minus platform color/logo)
- Create: `web/app/services/programs/scope_type.rb` (verbatim copy of `tmp/scope/web/app/services/programs/scope_type.rb`)
- Test: `web/test/models/program_test.rb`, `web/test/services/programs/scope_type_test.rb`

**Interfaces:**
- Produces: `Program.new(hash)` with accessors used across the module (`sid`, `platform`, `slug`, `name`, `bounty?`, `bounty_min/max`, `reward_avg/max`, `report_count`, `reports_24h/7d/month`, `avg_response_hrs`, `scope`, `out_of_scope`, `scope_count`, `public?`, `vdp?`, `collaboration?`, `hall_of_fame?`, `tags`, `languages`, `organization`, `policy`, `reward_grid`, `bounty_range`, `currency_symbol`, `to_param`); `Programs::ScopeType` (`CANONICAL`, `LABELS`, `canonical_for`, `canonicals_present`, `expand`, `label_for`).

- [ ] **Step 1: Write the failing test**

```ruby
# web/test/models/program_test.rb
require "test_helper"

class ProgramTest < ActiveSupport::TestCase
  test "bounty_range for a range" do
    p = Program.new("bounty" => true, "bounty_min" => 100, "bounty_max" => 5000, "currency" => "USD")
    assert_equal "$100 – $5,000", p.bounty_range
  end

  test "bounty_range for VDP" do
    assert_equal "No bounty", Program.new("bounty" => false).bounty_range
  end

  test "name falls back to a titleized slug" do
    assert_equal "Acme Corp", Program.new("slug" => "acme-corp").name
  end

  test "to_param is the sid" do
    assert_equal "abc", Program.new("_sid" => "abc").to_param
  end
end
```

```ruby
# web/test/services/programs/scope_type_test.rb
require "test_helper"

class Programs::ScopeTypeTest < ActiveSupport::TestCase
  test "canonical_for folds upstream tokens into buckets" do
    assert_equal :android, Programs::ScopeType.canonical_for("GOOGLE_PLAY_APP_ID")
    assert_equal :web,     Programs::ScopeType.canonical_for("URL")
    assert_equal :other,   Programs::ScopeType.canonical_for("mystery")
  end

  test "expand returns raw tokens for canonical keys" do
    assert_includes Programs::ScopeType.expand([:android]), "GOOGLE_PLAY_APP_ID"
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd web && bin/rails test test/models/program_test.rb test/services/programs/scope_type_test.rb`
Expected: FAIL — `uninitialized constant Program` / `Programs::ScopeType`.

- [ ] **Step 3: Copy the files and strip platform color/logo from the model**

```bash
cp tmp/scope/web/app/services/programs/scope_type.rb web/app/services/programs/scope_type.rb
cp tmp/scope/web/app/models/program.rb web/app/models/program.rb
```

Then edit `web/app/models/program.rb`: **delete** the `PLATFORM_COLORS`, `DEFAULT_COLORS`, `PLATFORM_LOGOS` constants and the `#colors`, `#platform_logo`, `#platform_logo?` methods (they encode platform-specific colors/logos, dropped for the monochrome skin). Keep everything else (data accessors, `bounty_range`, `currency_symbol`, `format_money`, `to_param`).

- [ ] **Step 4: Run to verify it passes**

Run: `cd web && bin/rails test test/models/program_test.rb test/services/programs/scope_type_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git -c user.name=Claude -c user.email=noreply@anthropic.com add web/app/models/program.rb web/app/services/programs/scope_type.rb web/test/models/program_test.rb web/test/services/programs/scope_type_test.rb
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Port Program model (minus platform colors) and Programs::ScopeType"
```

---

### Task 3: Ported search services — `SearchParser`, `DorkExpression`

**Files:**
- Create: `web/app/services/programs/dork_expression.rb` (verbatim copy)
- Create: `web/app/services/programs/search_parser.rb` (verbatim copy)
- Test: `web/test/services/programs/search_parser_test.rb`

**Interfaces:**
- Consumes: `Program` accessors (Task 2).
- Produces: `Programs::SearchParser.call(str)` → `Result(free_text:, expression:)`; `Programs::DorkExpression::{Term,And,Or}` with `#to_mongo` and `#evaluate(program)`.

- [ ] **Step 1: Write the failing test**

```ruby
# web/test/services/programs/search_parser_test.rb
require "test_helper"

class Programs::SearchParserTest < ActiveSupport::TestCase
  test "splits free text from a dork term" do
    r = Programs::SearchParser.call("acme asset:example.com")
    assert_equal "acme", r.free_text
    assert_equal({ "$or" => [
      { "scope.asset" => { "$regex" => "example\\.com", "$options" => "i" } },
      { "outofscope.asset" => { "$regex" => "example\\.com", "$options" => "i" } }
    ] }, r.expression.to_mongo)
  end

  test "AND binds tighter than OR" do
    r = Programs::SearchParser.call("bounty:yes AND platform:h1 OR platform:bc")
    assert_instance_of Programs::DorkExpression::Or, r.expression
  end

  test "plain prose with lowercase or stays free text" do
    r = Programs::SearchParser.call("cats or dogs")
    assert_nil r.expression
    assert_equal "cats or dogs", r.free_text
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd web && bin/rails test test/services/programs/search_parser_test.rb`
Expected: FAIL — `uninitialized constant Programs::SearchParser`.

- [ ] **Step 3: Copy the files verbatim**

```bash
cp tmp/scope/web/app/services/programs/dork_expression.rb web/app/services/programs/dork_expression.rb
cp tmp/scope/web/app/services/programs/search_parser.rb web/app/services/programs/search_parser.rb
```

No edits needed — these have no Mongo/ScopeMongo coupling.

- [ ] **Step 4: Run to verify it passes**

Run: `cd web && bin/rails test test/services/programs/search_parser_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git -c user.name=Claude -c user.email=noreply@anthropic.com add web/app/services/programs/dork_expression.rb web/app/services/programs/search_parser.rb web/test/services/programs/search_parser_test.rb
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Port Programs::SearchParser and DorkExpression verbatim"
```

---

### Task 4: Ported list services — `Filter`, `Sort`, `Source`

**Files:**
- Create: `web/app/services/programs/filter.rb` (verbatim copy)
- Create: `web/app/services/programs/sort.rb` (verbatim copy)
- Create: `web/app/services/programs/source.rb` (copy + `ScopeMongo`→`Programs::MongoSource` rename)
- Test: `web/test/services/programs/sort_test.rb`, `web/test/services/programs/filter_test.rb`

**Interfaces:**
- Consumes: `Program` (Task 2), `Programs::MongoSource` (Task 1), `Programs::ScopeType`, `Programs::DorkExpression`.
- Produces: `Programs::Filter.call(programs, params)` → filtered array; `Programs::Sort.call(programs, key, dir, favorited_sids:)`, `Programs::Sort::OPTIONS`, `Programs::Sort.resolve_dir(key, dir)`, `Programs::Sort::DEFAULT_KEY`; `Programs::Source.all/find(sid)/changes_since(t)/latest_update`.

- [ ] **Step 1: Write the failing test**

```ruby
# web/test/services/programs/sort_test.rb
require "test_helper"

class Programs::SortTest < ActiveSupport::TestCase
  def prog(sid, name) = Program.new("_sid" => sid, "name" => name)

  test "name sort ascending is case-insensitive" do
    a = prog("1", "beta"); b = prog("2", "Alpha")
    assert_equal %w[2 1], Programs::Sort.call([a, b], "name", "asc").map(&:sid)
  end

  test "resolve_dir falls back to the option default" do
    assert_equal "asc",  Programs::Sort.resolve_dir("name", nil)
    assert_equal "desc", Programs::Sort.resolve_dir("bounty_max", nil)
  end
end
```

```ruby
# web/test/services/programs/filter_test.rb
require "test_helper"

class Programs::FilterTest < ActiveSupport::TestCase
  def prog(attrs) = Program.new(attrs)

  test "by platform" do
    h1 = prog("_sid" => "1", "platform" => "hackerone")
    bc = prog("_sid" => "2", "platform" => "bugcrowd")
    out = Programs::Filter.call([h1, bc], { platforms: ["hackerone"] }.with_indifferent_access)
    assert_equal %w[1], out.map(&:sid)
  end

  test "by bounty with" do
    a = prog("_sid" => "1", "bounty" => true)
    b = prog("_sid" => "2", "bounty" => false)
    out = Programs::Filter.call([a, b], { bounty: "with" }.with_indifferent_access)
    assert_equal %w[1], out.map(&:sid)
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd web && bin/rails test test/services/programs/sort_test.rb test/services/programs/filter_test.rb`
Expected: FAIL — `uninitialized constant Programs::Sort` / `Programs::Filter`.

- [ ] **Step 3: Copy the files and rename the Mongo module in `source.rb`**

```bash
cp tmp/scope/web/app/services/programs/filter.rb web/app/services/programs/filter.rb
cp tmp/scope/web/app/services/programs/sort.rb   web/app/services/programs/sort.rb
cp tmp/scope/web/app/services/programs/source.rb web/app/services/programs/source.rb
```

In `web/app/services/programs/source.rb`, replace every `ScopeMongo.collection` with `Programs::MongoSource.collection` (there are 4 occurrences: in `changes_since`, `latest_update`, `mongo_docs`, `mongo_doc`). `Filter` and `Sort` need no edits.

- [ ] **Step 4: Run to verify it passes**

Run: `cd web && bin/rails test test/services/programs/sort_test.rb test/services/programs/filter_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git -c user.name=Claude -c user.email=noreply@anthropic.com add web/app/services/programs/filter.rb web/app/services/programs/sort.rb web/app/services/programs/source.rb web/test/services/programs/sort_test.rb web/test/services/programs/filter_test.rb
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Port Programs::Filter, Sort, and Source (ScopeMongo→Programs::MongoSource)"
```

---

### Task 5: Ported `Query` service (Mongo faceted search)

**Files:**
- Create: `web/app/services/programs/query.rb` (copy + `ScopeMongo`→`Programs::MongoSource` rename + index-call fix)
- Test: `web/test/services/programs/query_test.rb`

**Interfaces:**
- Consumes: all of the above.
- Produces: `Programs::Query.call(filter_params)` → `Result(programs:, total:, platforms:, scope_types:, bounty_ceiling:, page:, per_page:, has_next:)`.

- [ ] **Step 1: Write the failing test** (exercises the in-memory fallback path so no live Mongo is needed)

```ruby
# web/test/services/programs/query_test.rb
require "test_helper"

class Programs::QueryTest < ActiveSupport::TestCase
  def prog(sid, **attrs) = Program.new({ "_sid" => sid }.merge(attrs.transform_keys(&:to_s)))

  test "falls back to in-memory filter/sort when mongo is unusable" do
    programs = [prog("1", platform: "hackerone", name: "Beta"),
                prog("2", platform: "bugcrowd",  name: "Alpha")]
    stub_methods(Programs::MongoSource, healthy?: -> { false }) do
      stub_methods(Programs::Source, all: -> { programs }) do
        result = Programs::Query.call({ sort: "name", dir: "asc" }.with_indifferent_access)
        assert_equal %w[2 1], result.programs.map(&:sid)
        assert_equal 2, result.total
      end
    end
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd web && bin/rails test test/services/programs/query_test.rb`
Expected: FAIL — `uninitialized constant Programs::Query`.

- [ ] **Step 3: Copy and adapt**

```bash
cp tmp/scope/web/app/services/programs/query.rb web/app/services/programs/query.rb
```

In `web/app/services/programs/query.rb` apply these renames:
- Replace all `ScopeMongo.collection` with `Programs::MongoSource.collection`.
- Replace all `ScopeMongo.healthy?` with `Programs::MongoSource.healthy?`.
- Replace the call `ScopeMongo.ensure_indexes_once!` (no args, in `#call`) with `Programs::MongoSource.ensure_indexes_once!` (the wrapper already carries COLLECTION+INDEXES).

There are no other `ScopeMongo` references.

- [ ] **Step 4: Run to verify it passes**

Run: `cd web && bin/rails test test/services/programs/query_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git -c user.name=Claude -c user.email=noreply@anthropic.com add web/app/services/programs/query.rb web/test/services/programs/query_test.rb
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Port Programs::Query with Programs::MongoSource wiring"
```

---

### Task 6: Postgres user-state — migrations, models, User helpers

**Files:**
- Create: `web/db/migrate/20260709000001_create_favorites.rb`, `..._create_trashes.rb` (`...02`), `..._create_program_views.rb` (`...03`)
- Create: `web/app/models/favorite.rb`, `web/app/models/trash.rb`, `web/app/models/program_view.rb`
- Modify: `web/app/models/user.rb`
- Test: `web/test/models/user_program_state_test.rb`

**Interfaces:**
- Produces: `User#favorites/#trashes/#program_views` associations; `User#favorite_sids → Set`, `User#trash_sids → Set`, `User#recent_views(limit:) → [[Program, Time], ...]`.

- [ ] **Step 1: Write the migrations**

```ruby
# web/db/migrate/20260709000001_create_favorites.rb
class CreateFavorites < ActiveRecord::Migration[8.1]
  def change
    create_table :favorites do |t|
      t.references :user, null: false, foreign_key: true
      t.string :program_sid, null: false
      t.timestamps
    end
    add_index :favorites, [:user_id, :program_sid], unique: true
  end
end
```

```ruby
# web/db/migrate/20260709000002_create_trashes.rb
class CreateTrashes < ActiveRecord::Migration[8.1]
  def change
    create_table :trashes do |t|
      t.references :user, null: false, foreign_key: true
      t.string :program_sid, null: false
      t.timestamps
    end
    add_index :trashes, [:user_id, :program_sid], unique: true
  end
end
```

```ruby
# web/db/migrate/20260709000003_create_program_views.rb
class CreateProgramViews < ActiveRecord::Migration[8.1]
  def change
    create_table :program_views do |t|
      t.references :user, null: false, foreign_key: true
      t.string :program_sid, null: false
      t.datetime :viewed_at, null: false
      t.timestamps
    end
    add_index :program_views, [:user_id, :program_sid], unique: true
    add_index :program_views, [:user_id, :viewed_at]
  end
end
```

- [ ] **Step 2: Write the models**

```ruby
# web/app/models/favorite.rb
class Favorite < ApplicationRecord
  belongs_to :user
  validates :program_sid, presence: true, uniqueness: { scope: :user_id }
end
```

```ruby
# web/app/models/trash.rb
class Trash < ApplicationRecord
  belongs_to :user
  validates :program_sid, presence: true, uniqueness: { scope: :user_id }
end
```

```ruby
# web/app/models/program_view.rb
class ProgramView < ApplicationRecord
  belongs_to :user
  validates :program_sid, presence: true, uniqueness: { scope: :user_id }
end
```

- [ ] **Step 3: Extend the User model**

In `web/app/models/user.rb`, add inside the class body (after the existing `has_many` lines):

```ruby
  has_many :favorites, dependent: :destroy
  has_many :trashes, dependent: :destroy
  has_many :program_views, dependent: :destroy

  def favorite_sids
    @favorite_sids ||= favorites.pluck(:program_sid).to_set
  end

  def trash_sids
    @trash_sids ||= trashes.pluck(:program_sid).to_set
  end

  # Recent program views, newest first. Skips views whose Mongo program has
  # since disappeared. Returns [[Program, viewed_at], ...].
  def recent_views(limit: 10)
    rows = program_views.order(viewed_at: :desc).limit(limit).pluck(:program_sid, :viewed_at)
    rows.filter_map do |sid, ts|
      prog = Programs::Source.find(sid)
      prog && [prog, ts]
    end
  end
```

- [ ] **Step 4: Write the failing test**

```ruby
# web/test/models/user_program_state_test.rb
require "test_helper"

class UserProgramStateTest < ActiveSupport::TestCase
  setup { @user = User.create!(username: "hunter", password: "password123") }

  test "favorite_sids returns a set of sids" do
    @user.favorites.create!(program_sid: "abc")
    assert_equal Set["abc"], @user.favorite_sids
  end

  test "recent_views skips programs missing from mongo" do
    @user.program_views.create!(program_sid: "gone", viewed_at: Time.current)
    stub_methods(Programs::Source, find: ->(_sid) { nil }) do
      assert_empty @user.recent_views
    end
  end
end
```

- [ ] **Step 5: Migrate and run the test**

Run: `cd web && bin/rails db:migrate db:test:prepare && bin/rails test test/models/user_program_state_test.rb`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git -c user.name=Claude -c user.email=noreply@anthropic.com add web/db/migrate/2026070900000*_*.rb web/db/schema.rb web/app/models/favorite.rb web/app/models/trash.rb web/app/models/program_view.rb web/app/models/user.rb web/test/models/user_program_state_test.rb
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Add favorites, trashes, and program_views user-state tables and User helpers"
```

---

### Task 7: Routes + department base + toggle controllers

**Files:**
- Modify: `web/config/routes.rb`
- Create: `web/app/controllers/programs/base_controller.rb`
- Create: `web/app/controllers/programs/favorites_controller.rb`, `trashes_controller.rb`, `views_controller.rb`
- Modify: `web/app/helpers/navigation_helper.rb`
- Test: `web/test/integration/programs_user_state_test.rb`

**Interfaces:**
- Consumes: `Current.user`, user-state models (Task 6).
- Produces: routes `programs_root_path`, `programs_modal_path(sid)`, and `POST/DELETE /programs/:sid/favorite`, `.../trash`, `POST /programs/:sid/view`; `Programs::BaseController` with `TABS`.

- [ ] **Step 1: Replace the programs route line**

In `web/config/routes.rb`, replace `get "programs", to: "programs#index"` with:

```ruby
  namespace :programs do
    get "/",           to: "overview#index", as: :root
    get "/:sid/modal", to: "overview#modal", as: :modal
    post   "/:sid/favorite", to: "favorites#create"
    delete "/:sid/favorite", to: "favorites#destroy"
    post   "/:sid/trash",    to: "trashes#create"
    delete "/:sid/trash",    to: "trashes#destroy"
    post   "/:sid/view",     to: "views#create"
  end
```

- [ ] **Step 2: Write the department base controller**

```ruby
# web/app/controllers/programs/base_controller.rb
module Programs
  # Base for every controller in the Programs web department. Adding a tab is a
  # one-line change to TABS.
  class BaseController < ApplicationController
    include Department

    TABS = [
      { name: "Programs", path: :programs_root_path }
    ].freeze
  end
end
```

- [ ] **Step 3: Write the toggle controllers**

```ruby
# web/app/controllers/programs/favorites_controller.rb
module Programs
  class FavoritesController < BaseController
    def create
      fav = Current.user.favorites.find_or_create_by(program_sid: params[:sid])
      render json: { favorited: fav.persisted? }
    end

    def destroy
      Current.user.favorites.where(program_sid: params[:sid]).delete_all
      render json: { favorited: false }
    end
  end
end
```

```ruby
# web/app/controllers/programs/trashes_controller.rb
module Programs
  class TrashesController < BaseController
    def create
      rec = Current.user.trashes.find_or_create_by(program_sid: params[:sid])
      render json: { trashed: rec.persisted? }
    end

    def destroy
      Current.user.trashes.where(program_sid: params[:sid]).delete_all
      render json: { trashed: false }
    end
  end
end
```

```ruby
# web/app/controllers/programs/views_controller.rb
module Programs
  class ViewsController < BaseController
    def create
      rec = Current.user.program_views.find_or_initialize_by(program_sid: params[:sid])
      rec.viewed_at = Time.current
      rec.save
      render json: { tracked: rec.persisted?, viewed_at: rec.viewed_at }
    end
  end
end
```

- [ ] **Step 4: Update the sidebar nav link**

In `web/app/helpers/navigation_helper.rb`, change the Programs entry's `path: programs_path` to `path: programs_root_path`.

- [ ] **Step 5: Write the failing integration test**

```ruby
# web/test/integration/programs_user_state_test.rb
require "test_helper"

class ProgramsUserStateTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(username: "hunter", password: "password123")
    post session_path, params: { username: "hunter", password: "password123" }
  end

  test "favorite create then destroy" do
    post "/programs/abc/favorite", headers: { "X-Requested-With" => "XMLHttpRequest" }
    assert_response :success
    assert_equal true, JSON.parse(response.body)["favorited"]
    assert_equal 1, @user.favorites.count

    delete "/programs/abc/favorite", headers: { "X-Requested-With" => "XMLHttpRequest" }
    assert_response :success
    assert_equal 0, @user.favorites.reload.count
  end

  test "view tracks a program_view" do
    post "/programs/abc/view", headers: { "X-Requested-With" => "XMLHttpRequest" }
    assert_response :success
    assert_equal 1, @user.program_views.count
  end
end
```

Note: if the app's session login route/params differ, match `web/test/integration/sidebar_shell_test.rb`'s existing login helper.

- [ ] **Step 6: Run the test**

Run: `cd web && bin/rails test test/integration/programs_user_state_test.rb`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git -c user.name=Claude -c user.email=noreply@anthropic.com add web/config/routes.rb web/app/controllers/programs/ web/app/helpers/navigation_helper.rb web/test/integration/programs_user_state_test.rb
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Wire Programs department routes, base controller, and favorite/trash/view toggles"
```

---

### Task 8: Extend `IconHelper` with the glyphs the page needs

**Files:**
- Modify: `web/app/helpers/icon_helper.rb`
- Test: `web/test/helpers/icon_helper_test.rb`

**Interfaces:**
- Produces: `heroicon(name)` renders for the new keys: `magnifying-glass`, `star`, `squares-2x2`, `list-bullet`, `arrow-up`, `arrow-down`, `trash`, `clock`, `arrow-top-right-on-square`, `arrow-down-tray`, `clipboard`.

- [ ] **Step 1: Write the failing test**

```ruby
# web/test/helpers/icon_helper_test.rb
require "test_helper"

class IconHelperTest < ActionView::TestCase
  include IconHelper

  test "renders new program-page glyphs" do
    %w[magnifying-glass star squares-2x2 list-bullet arrow-up arrow-down
       trash clock arrow-top-right-on-square arrow-down-tray clipboard].each do |name|
      assert_match(/<svg/, heroicon(name), "expected #{name} to render")
    end
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd web && bin/rails test test/helpers/icon_helper_test.rb`
Expected: FAIL — `Unknown heroicon: magnifying-glass`.

- [ ] **Step 3: Add the paths** (Heroicons v2 outline, 24×24). Insert these entries into `HEROICON_PATHS` in `web/app/helpers/icon_helper.rb`:

```ruby
    "magnifying-glass" => [
      "M21 21l-5.197-5.197m0 0A7.5 7.5 0 105.196 5.196a7.5 7.5 0 0010.607 10.607z"
    ],
    "star" => [
      "M11.48 3.499a.562.562 0 011.04 0l2.125 5.111a.563.563 0 00.475.345l5.518.442c.499.04.701.663.321.988l-4.204 3.602a.563.563 0 00-.182.557l1.285 5.385a.562.562 0 01-.84.61l-4.725-2.885a.562.562 0 00-.586 0L6.982 20.54a.562.562 0 01-.84-.61l1.285-5.386a.562.562 0 00-.182-.557l-4.204-3.602a.562.562 0 01.321-.988l5.518-.442a.563.563 0 00.475-.345L11.48 3.5z"
    ],
    "squares-2x2" => [
      "M3.75 6A2.25 2.25 0 016 3.75h2.25A2.25 2.25 0 0110.5 6v2.25a2.25 2.25 0 01-2.25 2.25H6a2.25 2.25 0 01-2.25-2.25V6zM3.75 15.75A2.25 2.25 0 016 13.5h2.25a2.25 2.25 0 012.25 2.25V18a2.25 2.25 0 01-2.25 2.25H6A2.25 2.25 0 013.75 18v-2.25zM13.5 6a2.25 2.25 0 012.25-2.25H18A2.25 2.25 0 0120.25 6v2.25A2.25 2.25 0 0118 10.5h-2.25a2.25 2.25 0 01-2.25-2.25V6zM13.5 15.75a2.25 2.25 0 012.25-2.25H18a2.25 2.25 0 012.25 2.25V18A2.25 2.25 0 0118 20.25h-2.25A2.25 2.25 0 0113.5 18v-2.25z"
    ],
    "list-bullet" => [
      "M8.25 6.75h12M8.25 12h12m-12 5.25h12M3.75 6.75h.007v.008H3.75V6.75zm.375 0a.375.375 0 11-.75 0 .375.375 0 01.75 0zM3.75 12h.007v.008H3.75V12zm.375 0a.375.375 0 11-.75 0 .375.375 0 01.75 0zm-.375 5.25h.007v.008H3.75v-.008zm.375 0a.375.375 0 11-.75 0 .375.375 0 01.75 0z"
    ],
    "arrow-up" => [
      "M4.5 10.5L12 3m0 0l7.5 7.5M12 3v18"
    ],
    "arrow-down" => [
      "M19.5 13.5L12 21m0 0l-7.5-7.5M12 21V3"
    ],
    "trash" => [
      "M14.74 9l-.346 9m-4.788 0L9.26 9m9.968-3.21c.342.052.682.107 1.022.166m-1.022-.165L18.16 19.673a2.25 2.25 0 01-2.244 2.077H8.084a2.25 2.25 0 01-2.244-2.077L4.772 5.79m14.456 0a48.108 48.108 0 00-3.478-.397m-12 .562c.34-.059.68-.114 1.022-.165m0 0a48.11 48.11 0 013.478-.397m7.5 0v-.916c0-1.18-.91-2.164-2.09-2.201a51.964 51.964 0 00-3.32 0c-1.18.037-2.09 1.022-2.09 2.201v.916m7.5 0a48.667 48.667 0 00-7.5 0"
    ],
    "clock" => [
      "M12 6v6h4.5m4.5 0a9 9 0 11-18 0 9 9 0 0118 0z"
    ],
    "arrow-top-right-on-square" => [
      "M13.5 6H5.25A2.25 2.25 0 003 8.25v10.5A2.25 2.25 0 005.25 21h10.5A2.25 2.25 0 0018 18.75V10.5m-10.5 6L21 3m0 0h-5.25M21 3v5.25"
    ],
    "arrow-down-tray" => [
      "M3 16.5v2.25A2.25 2.25 0 005.25 21h13.5A2.25 2.25 0 0021 18.75V16.5M16.5 12L12 16.5m0 0L7.5 12m4.5 4.5V3"
    ],
    "clipboard" => [
      "M15.666 3.888A2.25 2.25 0 0013.5 2.25h-3c-1.03 0-1.9.693-2.166 1.638m7.332 0c.055.194.084.4.084.612v0a.75.75 0 01-.75.75H9a.75.75 0 01-.75-.75v0c0-.212.03-.418.084-.612m7.332 0c.646.049 1.288.11 1.927.184 1.1.128 1.907 1.077 1.907 2.185V19.5a2.25 2.25 0 01-2.25 2.25H6.75A2.25 2.25 0 014.5 19.5V6.257c0-1.108.806-2.057 1.907-2.185a48.208 48.208 0 011.927-.184"
    ],
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd web && bin/rails test test/helpers/icon_helper_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git -c user.name=Claude -c user.email=noreply@anthropic.com add web/app/helpers/icon_helper.rb web/test/helpers/icon_helper_test.rb
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Add program-page glyphs to IconHelper"
```

---

### Task 9: Port Stimulus controllers (re-skin + route alignment)

**Files:**
- Create in `web/app/javascript/controllers/`: `auto_submit_controller.js`, `auto_open_controller.js`, `column_sort_controller.js`, `dual_range_controller.js`, `range_controller.js`, `favorite_toggle_controller.js`, `trash_toggle_controller.js`, `grid_cols_controller.js`, `infinite_scroll_controller.js`, `modal_controller.js`, `modal_nav_controller.js`, `view_mode_controller.js`, `view_tracker_controller.js`, `scroll_top_controller.js`, `sort_dir_controller.js`, `asset_export_controller.js` (copies from `tmp/scope/web/app/javascript/controllers/`).

**Note:** Do **not** overwrite Hunter's existing `sidebar_controller.js` or `clipboard_controller.js`. Scope's programs sidebar uses a `data-controller="sidebar"` with `sidebar-target="main"`. Hunter already has a different `sidebar_controller.js` (top-nav). To avoid a collision, copy Scope's as `programs_sidebar_controller.js` and rename its identifier usage in the programs views to `programs-sidebar` (see Task 11). Reuse Hunter's existing `clipboard_controller.js` for copy buttons (do not port Scope's).

**Interfaces:**
- Produces: Stimulus controllers auto-registered by `eagerLoadControllersFrom`. `favorite-toggle`, `trash-toggle`, `view-tracker` POST to `/programs/:sid/favorite|trash|view` (already correct in Scope source — verify unchanged).

- [ ] **Step 1: Copy the controllers**

```bash
cd tmp/scope/web/app/javascript/controllers
cp auto_submit_controller.js auto_open_controller.js column_sort_controller.js \
   dual_range_controller.js range_controller.js favorite_toggle_controller.js \
   trash_toggle_controller.js grid_cols_controller.js infinite_scroll_controller.js \
   modal_controller.js modal_nav_controller.js view_mode_controller.js \
   view_tracker_controller.js scroll_top_controller.js sort_dir_controller.js \
   asset_export_controller.js \
   /home/claude/workspace/web/app/javascript/controllers/
cp sidebar_controller.js /home/claude/workspace/web/app/javascript/controllers/programs_sidebar_controller.js
```

- [ ] **Step 2: Re-skin the favorite toggle's color classes**

In `web/app/javascript/controllers/favorite_toggle_controller.js`, in `#render()`, replace the color-class toggles so both branches use Hunter monochrome (remove `text-gold`, `text-white/60`, `text-text-dim`, `opacity-*`):

```javascript
  #render() {
    const fav = this.favoritedValue
    this.element.dataset.favorited = fav ? "true" : "false"

    this.element.classList.toggle("text-zinc-900", fav)
    this.element.classList.toggle("dark:text-white", fav)
    this.element.classList.toggle("text-zinc-400", !fav)

    const svg = this.element.querySelector("svg")
    if (svg) svg.setAttribute("fill", fav ? "currentColor" : "none")

    const label = fav ? "Remove from favorites" : "Add to favorites"
    this.element.setAttribute("title", label)
    this.element.setAttribute("aria-label", fav ? "Unfavorite" : "Favorite")
  }
```

- [ ] **Step 3: Re-skin the trash toggle's color classes**

In `web/app/javascript/controllers/trash_toggle_controller.js`, in `#render()`, replace the color branch (remove `text-red-500`, red `drop-shadow`, `text-white/60`, `text-text-dim`, `opacity-*`) with monochrome:

```javascript
  #render() {
    const trashed = this.trashedValue
    this.element.dataset.trashed = trashed ? "true" : "false"

    this.element.classList.toggle("text-zinc-900", trashed)
    this.element.classList.toggle("dark:text-white", trashed)
    this.element.classList.toggle("text-zinc-400", !trashed)

    const label = trashed ? "Restore from trash" : "Move to trash"
    this.element.setAttribute("title", label)
    this.element.setAttribute("aria-label", label)
  }
```

- [ ] **Step 4: Rename the copied sidebar controller's target namespace**

The file `programs_sidebar_controller.js` is auto-registered under the identifier `programs-sidebar`. No code change is needed inside it (targets are relative to the identifier); the views (Task 11) reference `data-controller="programs-sidebar"` and `data-programs-sidebar-target="main"`.

- [ ] **Step 5: Verify assets compile**

Run: `cd web && bin/rails runner "Rails.application.assets" 2>/dev/null; ls app/javascript/controllers | grep -c _controller.js`
Expected: prints a count ≥ 27 (Hunter's original 12 + 15 new + programs_sidebar). No error.

- [ ] **Step 6: Commit**

```bash
git -c user.name=Claude -c user.email=noreply@anthropic.com add web/app/javascript/controllers/
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Port program-page Stimulus controllers and re-skin favorite/trash toggles"
```

---

### Task 10: Re-skinned catalog views — sidebar, cards, rows, chips, sort, history

**Files:**
- Create: `web/app/views/programs/index.html.erb` and partials `_sidebar`, `_card`, `_card_items`, `_row`, `_row_items`, `_cards`, `_skeleton_card`, `_active_chips`, `_sort_control`, `_history`, `_filter_range`, `_filter_dual_range` (copies of the Scope partials, re-skinned).
- Create: `web/app/controllers/programs/overview_controller.rb`
- Test: `web/test/integration/programs_overview_test.rb`

**Interfaces:**
- Consumes: `Programs::Query`, `Programs::Source`, `Programs::Sort`, `Programs::SearchParser`, `Current.user` state.
- Produces: `GET /programs` HTML; `GET /programs?...&page=2` with `X-Requested-With` → bare `programs/cards` partial (for infinite scroll); `GET /programs/:sid/modal` → modal fragment (wired in Task 11).

- [ ] **Step 1: Write the overview controller** (ported from Scope's `ProgramsController`, namespaced; the `helper_method` favorites/trash sets feed the views)

```ruby
# web/app/controllers/programs/overview_controller.rb
module Programs
  class OverviewController < BaseController
    def index
      fp = filter_params
      @favorited_sids = Current.user&.favorite_sids || Set.new
      @trashed_sids   = Current.user&.trash_sids   || Set.new
      @recent_views   = Current.user&.recent_views(limit: 12) || []
      @focused_program = fp[:focus].present? ? Programs::Source.find(fp[:focus]) : nil

      parsed = Programs::SearchParser.call(fp[:q])
      qp = fp.to_h.with_indifferent_access
      qp[:q] = parsed.free_text
      qp[:dork_expression] = parsed.expression
      qp[:_favorited_sids] = @favorited_sids
      qp[:_trashed_sids]   = @trashed_sids

      result = Programs::Query.call(qp)
      @programs       = result.programs
      @total          = result.total
      @platforms      = result.platforms
      @scope_types    = result.scope_types
      @bounty_ceiling = result.bounty_ceiling
      @filter_params  = fp
      @sort_key = Programs::Sort::OPTIONS.key?(fp[:sort]) ? fp[:sort] : Programs::Sort::DEFAULT_KEY
      @sort_dir = Programs::Sort.resolve_dir(@sort_key, fp[:dir])
      @page     = result.page
      @has_next = result.has_next

      render partial: "programs/cards", locals: cards_locals, layout: false if partial_request?
    end

    def modal
      program = Programs::Source.find(params[:sid])
      return head :not_found unless program
      render partial: "programs/modal", locals: { program: program }, layout: false
    end

    private

    def partial_request?
      request.xhr? || request.headers["X-Requested-With"] == "XMLHttpRequest"
    end

    def filter_params
      params.permit(
        :q, :status, :bounty, :collaboration, :favorites_only, :trash_only,
        :scope_count_gte, :scope_count_lte, :response_lte,
        :bounty_min_gte, :bounty_max_gte,
        :reports_gte, :reports_24h_gte, :reports_7d_gte, :reports_month_gte,
        :sort, :dir, :page, :per_page, :focus,
        platforms: [], scope_types: []
      )
    end

    def cards_locals
      { programs: @programs, page: @page, has_next: @has_next,
        filter_params: @filter_params, favorited_sids: @favorited_sids,
        trashed_sids: @trashed_sids }
    end
    helper_method :cards_locals
  end
end
```

- [ ] **Step 2: Copy the catalog view files**

```bash
cd tmp/scope/web/app/views/programs
cp index.html.erb _sidebar.html.erb _card.html.erb _card_items.html.erb \
   _row.html.erb _row_items.html.erb _cards.html.erb _skeleton_card.html.erb \
   _active_chips.html.erb _sort_control.html.erb _history.html.erb \
   _filter_range.html.erb _filter_dual_range.html.erb \
   /home/claude/workspace/web/app/views/programs/
```

- [ ] **Step 3: Re-skin every copied view file**

Apply the **Global Constraints** color-token map and icon-name map to all 13 files. File-specific edits:
- `index.html.erb`: change `content_for :title` to `"hunter — Programs"`; wrap the page body in Hunter's container by adding at top `<% content_for :container, "mx-auto max-w-screen-2xl px-6 py-10" %>` and remove Scope's bespoke `pl-14`/`data-locked` main-padding wrapper if it fights the Hunter layout (keep the `view-mode grid-cols infinite-scroll` controller div intact). Change `data-controller="auto-submit sidebar"` → `data-controller="auto-submit programs-sidebar"` and every `data-sidebar-target` → `data-programs-sidebar-target`. Replace all `icon "x", size: n` with `heroicon "x", classes: "h-4 w-4"` per the map.
- `_sidebar.html.erb`: same `sidebar`→`programs-sidebar` target rename; token + icon map. Uses `Programs::ScopeType.label_for` — unchanged.
- `_card.html.erb` / `_row.html.erb`: remove platform banner/logo image markup and `banner_fallback`/`logo_fallback`/`image_loaded` controllers (dropped); render `program.platform` as a zinc text badge. Keep `data-program-card` / `data-program-row` markers (infinite-scroll relies on them). Keep `favorite-toggle`/`trash-toggle` mounts; ensure the star/trash buttons render `heroicon "star"`/`heroicon "trash"`. Replace `program_favorited?`/`program_trashed?` helper calls (Scope had view helpers) with `favorited_sids.include?(program.sid)` / `trashed_sids.include?(program.sid)` using the partial locals.
- `_card_items.html.erb` / `_row_items.html.erb`: pass `favorited_sids`/`trashed_sids` locals through to each `_card`/`_row` render.
- `_cards.html.erb`: the XHR next-page partial — keep the `data-next-url` marker; token/icon map only.
- `_active_chips.html.erb`, `_sort_control.html.erb`, `_history.html.erb`, `_filter_range.html.erb`, `_filter_dual_range.html.erb`, `_skeleton_card.html.erb`: token + icon map only.

Verify no `pf-`, `text-brand`, `bg-brand`, `text-text`, `border-edge`, `text-gold`, or `icon "` strings remain:

```bash
cd /home/claude/workspace/web && ! grep -rEn "pf-|text-brand|bg-brand|text-text|border-edge|text-gold|icon \"" app/views/programs && echo CLEAN
```

- [ ] **Step 4: Write the failing integration test**

```ruby
# web/test/integration/programs_overview_test.rb
require "test_helper"

class ProgramsOverviewTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(username: "hunter", password: "password123")
    post session_path, params: { username: "hunter", password: "password123" }
  end

  test "renders the programs catalog with a stubbed result" do
    result = Programs::Query::Result.new(
      programs: [Program.new("_sid" => "1", "platform" => "hackerone", "name" => "Acme")],
      total: 1, platforms: ["hackerone"], scope_types: ["web"], bounty_ceiling: 1000,
      page: 1, per_page: 30, has_next: false
    )
    stub_methods(Programs::Query, call: ->(_qp) { result }) do
      get programs_root_path
    end
    assert_response :success
    assert_select "h1", /Programs/
    assert_match "Acme", response.body
  end
end
```

- [ ] **Step 5: Run the test**

Run: `cd web && bin/rails test test/integration/programs_overview_test.rb`
Expected: PASS. (Fix any leftover Scope helper references the errors surface — e.g. a missing `program_favorited?` — by switching to the `favorited_sids`/`trashed_sids` locals.)

- [ ] **Step 6: Commit**

```bash
git -c user.name=Claude -c user.email=noreply@anthropic.com add web/app/controllers/programs/overview_controller.rb web/app/views/programs/ web/test/integration/programs_overview_test.rb
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Add re-skinned Programs catalog views and overview controller"
```

---

### Task 11: Re-skinned program detail modal (server-side HTML sanitize)

**Files:**
- Create: `web/app/views/programs/_modal.html.erb` (copy of Scope's, re-skinned; DOMPurify → server sanitize)
- Test: `web/test/integration/programs_modal_test.rb`

**Interfaces:**
- Consumes: `GET /programs/:sid/modal` (Task 10 controller). The modal mounts `data-controller="modal view-tracker"` and inner `modal-nav`, `asset-export`, `clipboard`.

- [ ] **Step 1: Copy the modal**

```bash
cp tmp/scope/web/app/views/programs/_modal.html.erb web/app/views/programs/_modal.html.erb
```

- [ ] **Step 2: Re-skin + drop DOMPurify**

- Apply the color-token and icon-name maps throughout.
- Remove the platform banner/hero image + gradient (`pf-banner-*`) markup; render a plain zinc header with `program.name` and a neutral platform badge.
- Replace every `data-controller="purified-html"` usage (which rendered `rules_html`/`account_access_html` client-side via DOMPurify) with server-side sanitized output. For each such block, render:

```erb
<div class="prose prose-sm dark:prose-invert max-w-none">
  <%= sanitize program.rules_html,
        tags: %w[p br ul ol li strong em a code pre h1 h2 h3 h4 blockquote table thead tbody tr th td],
        attributes: %w[href title] %>
</div>
```

(and the analogous block for `program.account_access_html?` / `account_access_html`). Remove any `purified-html` targets/values.
- Keep `data-controller="modal view-tracker"` on the `<dialog>`, `data-view-tracker-sid-value="<%= program.sid %>"`, the `modal-nav` outline, `asset-export`, and copy buttons (use Hunter's `clipboard` controller).

Verify:

```bash
cd /home/claude/workspace/web && ! grep -En "purified-html|pf-banner|text-brand|icon \"" app/views/programs/_modal.html.erb && echo CLEAN
```

- [ ] **Step 3: Write the failing test**

```ruby
# web/test/integration/programs_modal_test.rb
require "test_helper"

class ProgramsModalTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(username: "hunter", password: "password123")
    post session_path, params: { username: "hunter", password: "password123" }
  end

  test "modal renders and strips script tags from policy html" do
    program = Program.new("_sid" => "1", "name" => "Acme", "platform" => "hackerone",
                          "policy" => { "rules_html" => "<p>ok</p><script>alert(1)</script>" })
    stub_methods(Programs::Source, find: ->(_sid) { program }) do
      get programs_modal_path(sid: "1"), headers: { "X-Requested-With" => "XMLHttpRequest" }
    end
    assert_response :success
    assert_match "Acme", response.body
    assert_match "<p>ok</p>", response.body
    assert_no_match(/<script>alert/, response.body)
  end

  test "modal 404s for a missing program" do
    stub_methods(Programs::Source, find: ->(_sid) { nil }) do
      get programs_modal_path(sid: "nope"), headers: { "X-Requested-With" => "XMLHttpRequest" }
    end
    assert_response :not_found
  end
end
```

- [ ] **Step 4: Run the test**

Run: `cd web && bin/rails test test/integration/programs_modal_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git -c user.name=Claude -c user.email=noreply@anthropic.com add web/app/views/programs/_modal.html.erb web/test/integration/programs_modal_test.rb
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Add re-skinned program modal with server-side policy HTML sanitize"
```

---

### Task 12: Dev seeds + full suite green

**Files:**
- Modify: `web/db/seeds.rb`
- Create: `web/test/fixtures/files/program_sample.json` (copied from Scope test asset, optional data source for the seed)

**Interfaces:**
- Produces: an idempotent seed that upserts a few sample programs into the `programs` Mongo collection when empty.

- [ ] **Step 1: Copy a sample program fixture**

```bash
mkdir -p web/test/fixtures/files
cp tmp/scope/tests/assets/program.json web/test/fixtures/files/program_sample.json
```

- [ ] **Step 2: Add a guarded seed block**

Append to `web/db/seeds.rb`:

```ruby
# Programs module — seed a few sample programs into Mongo for local dev so the
# catalog page has content. No-op when the collection already has data or Mongo
# is unreachable.
begin
  if HunterMongo.healthy? && Programs::MongoSource.collection.estimated_document_count.zero?
    samples = [
      { "_sid" => "seed-h1-acme", "platform" => "hackerone", "slug" => "acme",
        "name" => "Acme", "public" => true, "bounty" => true, "bounty_min" => 100,
        "bounty_max" => 5000, "currency" => "USD", "scope_count" => 3,
        "report_count" => 42, "collaboration" => true, "updated_at" => Time.current,
        "scope" => [{ "asset" => "*.acme.com", "type" => "WILDCARD" }] },
      { "_sid" => "seed-bc-globex", "platform" => "bugcrowd", "slug" => "globex",
        "name" => "Globex", "public" => true, "bounty" => true, "bounty_max" => 10000,
        "currency" => "USD", "scope_count" => 1, "report_count" => 8,
        "updated_at" => Time.current,
        "scope" => [{ "asset" => "api.globex.com", "type" => "API" }] }
    ]
    samples.each do |doc|
      Programs::MongoSource.collection.update_one({ _sid: doc["_sid"] }, { "$set" => doc }, upsert: true)
    end
    puts "Seeded #{samples.size} sample programs into Mongo."
  end
rescue Mongo::Error => e
  warn "Skipped program seeds (mongo: #{e.message})"
end
```

- [ ] **Step 3: Run the full test suite**

Run: `cd web && bin/rails test`
Expected: PASS — all suites, 0 failures, 0 errors.

- [ ] **Step 4: Commit**

```bash
git -c user.name=Claude -c user.email=noreply@anthropic.com add web/db/seeds.rb web/test/fixtures/files/program_sample.json
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Seed sample programs for local dev and green the Programs module suite"
```

---

## Self-Review

**Spec coverage:**
- §2 module shape → Tasks 1–11 (services, models, controllers, views, JS all under `Programs::`). ✓
- §3 Mongo wiring (ScopeMongo→HunterMongo) → Tasks 1, 4, 5. ✓
- §4 re-skin (tokens, icons, dropped platform colors/logos) → Global Constraints + Tasks 2 (model constants), 8 (icons), 9–11 (views/JS). ✓
- §5 user-state (favorites/trash/views + User helpers) → Task 6; controllers Task 7. ✓
- §6 Stimulus controllers incl. purified_html→sanitize substitution and dropped image-fallbacks → Tasks 9, 11. ✓
- §7 routes + nav → Task 7. ✓
- §8 tests (service/controller/model) → Tasks 1–7, 10, 11 each ship tests; Task 12 full suite. ✓
- §9 out-of-scope (config/logs/monitor, JSON API, snapshots, logos) → not implemented, as intended. ✓

**Placeholder scan:** No TBD/TODO. "Copy" steps name exact source paths in `tmp/scope/`; transform steps enumerate exact token/icon maps and file-specific edits; new files are shown in full. ✓

**Type/name consistency:** `Programs::MongoSource.{collection,ensure_indexes_once!,healthy?}` defined in Task 1 and consumed identically in Tasks 4/5/12. `Result` struct fields match the controller reads in Task 10. `favorited_sids`/`trashed_sids` locals introduced in Task 10 and used consistently across `_card`/`_row`/`_card_items`/`_row_items`. Route names `programs_root_path`/`programs_modal_path` defined in Task 7 and used in Tasks 10/11. ✓

**Known risk to watch during execution:** the session-login helper in the integration tests (`post session_path, params: {...}`) must match Hunter's actual auth flow — mirror `web/test/integration/sidebar_shell_test.rb` if it differs. Flagged in Task 7 Step 5.
