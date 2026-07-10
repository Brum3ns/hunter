# Vulnerabilities Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the vulnerability-management web department — a single monochrome screen with summary stat cards on top and a searchable, filterable, paginated findings list below.

**Architecture:** Server-rendered Hotwire department. A namespaced `Vulnerabilities::OverviewController` (via a reusable `Department` concern) renders HTML by calling `Vulnerabilities::MongoSource` (list/search/filter/page) and a new `Vulnerabilities::Stats` service (counts) directly. The existing `/api/v1/vulnerabilities` JSON API stays as the programmatic surface and shares the same service layer.

**Tech Stack:** Rails 8, Tailwind v4, importmap + Stimulus/Turbo, Minitest, MongoDB via `HunterMongo`.

## Global Constraints

- **DO NOT COMMIT.** The final step of each task is `git add` only — the user commits on "go".
- Monochrome only — no color accents; severity is a grayscale ramp.
- Mongo is doubled in tests (`stub_methods` helper); no live Mongo.
- Each module's web department stays isolated; central touch-points limited to a routes block + one sidebar entry.

---

### Task 1: Search in `Vulnerabilities::MongoSource`

**Files:**
- Modify: `web/app/services/vulnerabilities/mongo_source.rb`
- Test: `web/test/services/vulnerabilities/mongo_source_test.rb`

**Interfaces:**
- Produces: `MongoSource.all(filters:, search:, page:, limit:)`, `MongoSource.count(filters:, search:)` — `search` builds an `$or` of case-insensitive regexes on `finding.name` + `target.host`, AND-combined with existing filters.

- [ ] **Step 1:** Add a test asserting `build_filter` (via `all`/`count` with a doubled collection) AND-combines `severity` with a `search` `$or`.
- [ ] **Step 2:** Run it — expect failure (search ignored).
- [ ] **Step 3:** Add `search:` keyword to `all`/`count`; change `build_filter(filters, search = nil)` to append `base["$or"] = [{ "finding.name" => rx }, { "target.host" => rx }]` when search present (`rx = { "$regex" => Regexp.escape(search.to_s), "$options" => "i" }`).
- [ ] **Step 4:** Run tests — pass.
- [ ] **Step 5:** `git add` the two files.

---

### Task 2: `Vulnerabilities::Stats` service

**Files:**
- Create: `web/app/services/vulnerabilities/stats.rb`
- Test: `web/test/services/vulnerabilities/stats_test.rb`

**Interfaces:**
- Produces: `Stats.summary → { created:, resolved:, false_positives: }`. `RESOLVED_STATUSES = %w[resolved closed fixed]`, `FALSE_POSITIVE_STATUSES = %w[false_positive fp]`. Counts via `count_documents`; returns zeros on `Mongo::Error`.

- [ ] **Step 1:** Test: stub `Stats.collection` with a double whose `count_documents` returns scripted values; assert `summary` maps to the right keys and `$in` filters.
- [ ] **Step 2:** Run — fail (no file).
- [ ] **Step 3:** Implement `module Vulnerabilities::Stats` (module_function): `summary` calls `count({})`, `count("report.status" => { "$in" => RESOLVED_STATUSES })`, `count("report.status" => { "$in" => FALSE_POSITIVE_STATUSES })`; wrap in `rescue Mongo::Error` → zeros. `collection` → `HunterMongo.collection(MongoSource::COLLECTION)`.
- [ ] **Step 4:** Run — pass.
- [ ] **Step 5:** `git add`.

---

### Task 3: JSON API accepts `q`

**Files:**
- Modify: `web/app/controllers/api/v1/vulnerabilities_controller.rb`
- Test: `web/test/integration/api/v1/vulnerabilities_test.rb` (add a case)

**Interfaces:**
- Consumes: `MongoSource.all/count` `search:` from Task 1.

- [ ] **Step 1:** Test: GET `/api/v1/vulnerabilities?q=sql` forwards `search: "sql"` to a stubbed `MongoSource.all`.
- [ ] **Step 2:** Run — fail.
- [ ] **Step 3:** Permit `:q`; pass `search: params[:q]` into `MongoSource.all`/`count`.
- [ ] **Step 4:** Run — pass.
- [ ] **Step 5:** `git add`.

---

### Task 4: `Department` concern + namespaced web controllers + route + nav

**Files:**
- Create: `web/app/controllers/concerns/department.rb`
- Create: `web/app/controllers/vulnerabilities/base_controller.rb`
- Create: `web/app/controllers/vulnerabilities/overview_controller.rb`
- Delete: `web/app/controllers/vulnerabilities_controller.rb`
- Modify: `web/config/routes.rb` (replace `get "vulnerabilities"...` with `namespace :vulnerabilities { get "/", to: "overview#index", as: :root }`)
- Modify: `web/app/helpers/navigation_helper.rb` (`nav_active?` matches `controller_path` first segment; Vulnerabilities entry → `vulnerabilities_root_path`)
- Test: `web/test/integration/vulnerabilities/overview_test.rb`

**Interfaces:**
- Produces: route `vulnerabilities_root_path` → `/vulnerabilities`; `OverviewController#index` reads `q/severity/status/page`, assigns `@findings`, `@total`, `@stats`, `@page`, `@limit`, `@filters` by calling `MongoSource`/`Stats`.

- [ ] **Step 1:** Test: authenticated GET `vulnerabilities_root_path` renders 200 with stubbed `MongoSource`/`Stats`; forwards `q`; sidebar shows Vulnerabilities active.
- [ ] **Step 2:** Run — fail.
- [ ] **Step 3:** Add `Department` concern (`helper_method :department_tabs`, reads `self.class::TABS` if defined else `[]`). `Vulnerabilities::BaseController < ApplicationController; include Department; TABS = [{ name: "Vulnerabilities", path: :vulnerabilities_root_path }]`. `OverviewController#index` builds ivars. Update route + `nav_active?` + nav entry. Delete old controller.
- [ ] **Step 4:** Run — pass.
- [ ] **Step 5:** `git add` (use `git add -A` for the deletion).

---

### Task 5: Opt-in layout container + SparklineHelper

**Files:**
- Modify: `web/app/views/layouts/application.html.erb`
- Create: `web/app/helpers/sparkline_helper.rb`
- Test: `web/test/helpers/sparkline_helper_test.rb`

- [ ] **Step 1:** Test: `sparkline([1,2,3])` returns an `<svg>`; `sparkline([])` returns `nil`.
- [ ] **Step 2:** Run — fail.
- [ ] **Step 3:** Implement `SparklineHelper#sparkline(series)` (inline SVG polyline; `nil` for blank). Make layout container opt-in: `<% container = content_for?(:container) ? yield(:container).strip : "mx-auto max-w-6xl px-6 py-10" %>` then `<div class="<%= container %>">`.
- [ ] **Step 4:** Run — pass.
- [ ] **Step 5:** `git add`.

---

### Task 6: Views — stat cards, filters, findings table, badges, pagination

**Files:**
- Create: `web/app/views/vulnerabilities/overview/index.html.erb`
- Create: `web/app/views/vulnerabilities/overview/_stat_cards.html.erb`, `_stat_card.html.erb`, `_filters.html.erb`, `_findings_table.html.erb`, `_finding_row.html.erb`, `_severity_badge.html.erb`, `_status_badge.html.erb`
- Create: `web/app/views/shared/_pagination.html.erb`
- Create: `web/app/javascript/controllers/filter_form_controller.js` (+ register in `controllers/index.js`)
- Delete: any stale `web/app/views/vulnerabilities/index.html.erb`

- [ ] **Step 1:** Build `index` setting `content_for :container, "mx-auto max-w-screen-2xl px-6 py-10"`, composing the partials with `@stats/@findings/@total/@filters/@page/@limit`.
- [ ] **Step 2:** Stat cards (Created/Resolved/False Positives, optional sparkline). Filters partial = Turbo GET form (search + severity + status selects) `data-controller="filter_form"`. Findings table columns Severity·Status·Name·Target·Tool·Date via an ordered column list, one `_finding_row` per finding; monochrome severity/status badges; empty state. Shared `_pagination` (prev/next + page indicator preserving filters).
- [ ] **Step 3:** `filter_form` Stimulus controller auto-submits on `change`/debounced `input`.
- [ ] **Step 4:** Run full suite: `bin/rails test` — green.
- [ ] **Step 5:** `git add -A`.

---

## Self-Review

- Spec coverage: web shell (T4), search (T1), Stats (T2), API `q` (T3), opt-in container + sparkline (T5), views/JS/pagination (T6) — all covered.
- Type consistency: `MongoSource.all/count(... search:)`, `Stats.summary` keys `created/resolved/false_positives`, `vulnerabilities_root_path`, `department_tabs` — used consistently across tasks.
- No placeholders.
