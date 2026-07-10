# Vulnerability Tab — Severity Colors + Editable Status Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Color the vulnerability-table severity badges and make each vuln's status editable inline from the table, persisted to Mongo with attribution.

**Architecture:** Severity colors are a data-only change to `VulnerabilitiesHelper::SEVERITY_CLASSES`. Status becomes editable via an inline `<select>` that auto-submits (Stimulus) to a new `Vulnerabilities::StatusesController#update`, which writes `report.status` + attribution through the existing `Vulnerabilities::MongoSource` and answers with a Turbo Stream that swaps the row's status cell.

**Tech Stack:** Ruby 3.3.6, Rails 8, Tailwind CSS v4, importmap + Stimulus/Turbo (Hotwire), MongoDB (via `HunterMongo`), Minitest.

## Global Constraints

- Ruby 3.3.6, Rails 8, Tailwind CSS v4 (`@import "tailwindcss"`, class-based dark via `.dark`).
- Monochrome design language everywhere **except** the severity badges in the findings table. Status badges/selects stay monochrome.
- Status vocabulary is exactly `new triage reported close false_positive`. Any other/blank/legacy value (`unreviewed`) **displays as `new`**.
- Status is shared (one value per vuln), attributed to the acting user (`Current.user.username`) with a UTC timestamp.
- Persistence is Mongo only (`report.*` subfields) via `Vulnerabilities::MongoSource`; no Postgres table. Mongo **write** failures propagate (→ 502); no data migration of legacy values.
- Tests must not require a live Mongo — double the collection / stub the service via the `stub_methods` helper in `web/test/test_helper.rb`.
- All commands run from `web/`.
- Commit author is Claude; commit messages are a single sentence. Use per-invocation overrides:
  `git -c user.name="Claude" -c user.email="noreply@anthropic.com" commit -m "<one sentence>"`

---

### Task 1: Severity badge colors

**Files:**
- Modify: `web/app/helpers/vulnerabilities_helper.rb` (the `SEVERITY_CLASSES` map)
- Test: `web/test/helpers/vulnerabilities_helper_test.rb` (create)

**Interfaces:**
- Consumes: nothing new.
- Produces: `severity_badge_classes(severity)` returns colored Tailwind classes; still falls back to the `info` entry for unknown values.

- [ ] **Step 1: Write the failing test**

Create `web/test/helpers/vulnerabilities_helper_test.rb`:

```ruby
require "test_helper"

class VulnerabilitiesHelperTest < ActionView::TestCase
  test "severity_badge_classes returns colored classes per severity" do
    assert_includes severity_badge_classes("critical"), "bg-red-100"
    assert_includes severity_badge_classes("high"),     "bg-orange-100"
    assert_includes severity_badge_classes("medium"),   "bg-amber-100"
    assert_includes severity_badge_classes("low"),      "bg-blue-100"
    assert_includes severity_badge_classes("info"),     "bg-zinc-200"
  end

  test "severity_badge_classes carries dark-mode variants" do
    assert_includes severity_badge_classes("critical"), "dark:bg-red-950"
    assert_includes severity_badge_classes("high"),     "dark:bg-orange-950"
  end

  test "severity_badge_classes falls back to info for unknown severity" do
    assert_equal severity_badge_classes("info"), severity_badge_classes("nonsense")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/helpers/vulnerabilities_helper_test.rb`
Expected: FAIL — current classes are `bg-zinc-*`, so the `bg-red-100`/`bg-orange-100`/etc. assertions fail.

- [ ] **Step 3: Replace the severity map**

In `web/app/helpers/vulnerabilities_helper.rb`, replace the `SEVERITY_CLASSES` constant and its leading comment with:

```ruby
  # Severity ramp. Deliberate, contained break from the app's monochrome design:
  # only these table badges carry color. info stays gray. Dark-mode variants
  # included. Tailwind v4 auto-scans this .rb, so literal classes are not purged.
  SEVERITY_CLASSES = {
    "critical" => "bg-red-100 text-red-700 dark:bg-red-950 dark:text-red-300",
    "high"     => "bg-orange-100 text-orange-700 dark:bg-orange-950 dark:text-orange-300",
    "medium"   => "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300",
    "low"      => "bg-blue-100 text-blue-700 dark:bg-blue-950 dark:text-blue-300",
    "info"     => "bg-zinc-200 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-400"
  }.freeze
```

Leave `severity_badge_classes` unchanged (it already fetches with an `info` fallback).

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/helpers/vulnerabilities_helper_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git -c user.name="Claude" -c user.email="noreply@anthropic.com" \
  add app/helpers/vulnerabilities_helper.rb test/helpers/vulnerabilities_helper_test.rb
git -c user.name="Claude" -c user.email="noreply@anthropic.com" \
  commit -m "Color vulnerability severity badges while keeping the rest of the app monochrome"
```

---

### Task 2: Status vocabulary + display normalization

**Files:**
- Modify: `web/app/helpers/vulnerabilities_helper.rb` (`STATUSES`, add `display_status`)
- Test: `web/test/helpers/vulnerabilities_helper_test.rb` (append)

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `VulnerabilitiesHelper::STATUSES == %w[new triage reported close false_positive]`
  - `status_select_options` → `[["New","new"],["Triage","triage"],["Reported","reported"],["Close","close"],["False positive","false_positive"]]`
  - `display_status(raw)` → a value in `STATUSES` passes through (case-insensitively); anything else (blank/`nil`/`unreviewed`) → `"new"`.

- [ ] **Step 1: Write the failing test**

Append to `web/test/helpers/vulnerabilities_helper_test.rb`:

```ruby
  test "STATUSES is the new five-value vocabulary" do
    assert_equal %w[new triage reported close false_positive], VulnerabilitiesHelper::STATUSES
  end

  test "display_status passes known statuses through" do
    %w[new triage reported close false_positive].each do |s|
      assert_equal s, display_status(s)
    end
  end

  test "display_status defaults blank and legacy values to new" do
    assert_equal "new", display_status("unreviewed")
    assert_equal "new", display_status("")
    assert_equal "new", display_status(nil)
  end

  test "status_select_options humanizes each status" do
    assert_includes status_select_options, ["False positive", "false_positive"]
    assert_includes status_select_options, ["New", "new"]
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/helpers/vulnerabilities_helper_test.rb`
Expected: FAIL — `STATUSES` is currently the old six values and `display_status` is undefined.

- [ ] **Step 3: Update the vocabulary and add the helper**

In `web/app/helpers/vulnerabilities_helper.rb`, replace the `STATUSES` line:

```ruby
  STATUSES = %w[new triage reported close false_positive].freeze
```

Then add this method (e.g. below `status_select_options`):

```ruby
  # Legacy/blank Mongo statuses render as "new"; recognized values pass through.
  def display_status(raw)
    value = raw.to_s.downcase
    STATUSES.include?(value) ? value : "new"
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/helpers/vulnerabilities_helper_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git -c user.name="Claude" -c user.email="noreply@anthropic.com" \
  add app/helpers/vulnerabilities_helper.rb test/helpers/vulnerabilities_helper_test.rb
git -c user.name="Claude" -c user.email="noreply@anthropic.com" \
  commit -m "Adopt the new-triage-reported-close-false_positive status vocabulary with legacy fallback"
```

---

### Task 3: `MongoSource.update_status`

**Files:**
- Modify: `web/app/services/vulnerabilities/mongo_source.rb` (add `update_status`)
- Test: `web/test/services/vulnerabilities/mongo_source_test.rb` (create)

**Interfaces:**
- Consumes: existing `update(id, attrs)` (ObjectId-addressed `$set`, returns the refreshed normalized doc or `nil`); `VulnerabilitiesHelper::STATUSES`.
- Produces: `Vulnerabilities::MongoSource.update_status(id:, status:, user:)` — validates `status` ∈ `STATUSES` (else `ArgumentError`), `$set`s `report.status`, `report.status_updated_by` (= `user.username`), `report.status_updated_at` (= UTC `Time`), returns the refreshed doc or `nil`. A `Mongo::Error` from the write propagates.

- [ ] **Step 1: Write the failing test**

Create `web/test/services/vulnerabilities/mongo_source_test.rb`:

```ruby
require "test_helper"

class Vulnerabilities::MongoSourceTest < ActiveSupport::TestCase
  Source = Vulnerabilities::MongoSource
  OID = "507f1f77bcf86cd799439011" # valid 24-hex ObjectId string

  def fake_collection(&update_one)
    Object.new.tap { |o| o.define_singleton_method(:update_one, &update_one) }
  end

  test "update_status $sets status and attribution, returning the refreshed doc" do
    user = users(:one)
    captured = nil
    coll = fake_collection { |_filter, update| captured = update; Struct.new(:matched_count).new(1) }

    result = stub_methods(Source, collection: coll, find: { "id" => OID, "report" => { "status" => "triage" } }) do
      Source.update_status(id: OID, status: "triage", user: user)
    end

    set = captured["$set"]
    assert_equal "triage",        set["report.status"]
    assert_equal user.username,   set["report.status_updated_by"]
    assert_kind_of Time,          set["report.status_updated_at"]
    assert_equal({ "id" => OID, "report" => { "status" => "triage" } }, result)
  end

  test "update_status rejects an unknown status without writing" do
    user = users(:one)
    wrote = false
    coll = fake_collection { |*| wrote = true; Struct.new(:matched_count).new(1) }

    stub_methods(Source, collection: coll) do
      assert_raises(ArgumentError) { Source.update_status(id: OID, status: "bogus", user: user) }
    end
    refute wrote
  end

  test "update_status lets a Mongo write error propagate" do
    user = users(:one)
    coll = fake_collection { |*| raise Mongo::Error, "boom" }

    stub_methods(Source, collection: coll) do
      assert_raises(Mongo::Error) { Source.update_status(id: OID, status: "triage", user: user) }
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/vulnerabilities/mongo_source_test.rb`
Expected: FAIL — `update_status` is undefined (`NoMethodError`).

- [ ] **Step 3: Add `update_status`**

In `web/app/services/vulnerabilities/mongo_source.rb`, add this method right after `update` (keep it public, above `collection`):

```ruby
    # Sets the shared status plus attribution (who + when) on a vulnerability.
    # Validates the vocabulary here so a bad value never reaches Mongo. Reuses
    # `update` (ObjectId-addressed $set with dotted keys, so the rest of `report`
    # is preserved). Write failures propagate as Mongo::Error (-> 502).
    def update_status(id:, status:, user:)
      unless VulnerabilitiesHelper::STATUSES.include?(status.to_s)
        raise ArgumentError, "invalid status: #{status.inspect}"
      end
      update(id, {
        "report.status"            => status.to_s,
        "report.status_updated_by" => user.username,
        "report.status_updated_at" => Time.now.utc
      })
    end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/services/vulnerabilities/mongo_source_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git -c user.name="Claude" -c user.email="noreply@anthropic.com" \
  add app/services/vulnerabilities/mongo_source.rb test/services/vulnerabilities/mongo_source_test.rb
git -c user.name="Claude" -c user.email="noreply@anthropic.com" \
  commit -m "Add MongoSource.update_status to persist vulnerability status with attribution"
```

---

### Task 4: Inline status dropdown + endpoint (end-to-end)

**Files:**
- Modify: `web/config/routes.rb` (add the `statuses#update` route inside `namespace :vulnerabilities`)
- Create: `web/app/controllers/vulnerabilities/statuses_controller.rb`
- Create: `web/app/views/vulnerabilities/statuses/update.turbo_stream.erb`
- Rewrite: `web/app/views/vulnerabilities/overview/_status_badge.html.erb` (badge → auto-submitting select form)
- Modify: `web/app/views/vulnerabilities/overview/_finding_row.html.erb` (status `<td>` gets a stable id + passes `finding:`)
- Create: `web/app/javascript/controllers/status_select_controller.js`
- Test: `web/test/integration/vulnerabilities/statuses_test.rb` (create)

**Interfaces:**
- Consumes: `Vulnerabilities::MongoSource.update_status(id:, status:, user:)`; `::Vulnerability.new(doc)`; helpers `status_select_options`, `display_status`.
- Produces: route helper `vulnerabilities_status_path(id)` (PATCH); Turbo Stream that `replace`s the element `status_cell_<id>`.

- [ ] **Step 1: Write the failing integration test**

Create `web/test/integration/vulnerabilities/statuses_test.rb`:

```ruby
require "test_helper"

class Vulnerabilities::StatusesTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }
  Source = Vulnerabilities::MongoSource

  DOC = {
    "id" => "abc",
    "finding" => { "name" => "XSS", "severity" => "high" },
    "report"  => { "status" => "triage" }
  }.freeze

  test "redirects an unauthenticated visitor to sign in" do
    patch vulnerabilities_status_path("abc"), params: { status: "triage" }
    assert_redirected_to new_session_path
  end

  test "updates status and renders a turbo stream replacing the status cell" do
    sign_in_as(@user)
    captured = nil
    stub = ->(id:, status:, user:) { captured = { id: id, status: status, user: user }; DOC }

    stub_methods(Source, update_status: stub) do
      patch vulnerabilities_status_path("abc"), params: { status: "triage" }, as: :turbo_stream
    end

    assert_response :success
    assert_equal "abc",    captured[:id]
    assert_equal "triage", captured[:status]
    assert_equal @user,    captured[:user]
    assert_select "turbo-stream[action=replace][target=status_cell_abc]"
  end

  test "returns 400 for an invalid status" do
    sign_in_as(@user)
    stub_methods(Source, update_status: ->(**) { raise ArgumentError }) do
      patch vulnerabilities_status_path("abc"), params: { status: "bogus" }, as: :turbo_stream
    end
    assert_response :bad_request
  end

  test "returns 404 when the vulnerability is not found" do
    sign_in_as(@user)
    stub_methods(Source, update_status: nil) do
      patch vulnerabilities_status_path("missing"), params: { status: "triage" }, as: :turbo_stream
    end
    assert_response :not_found
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/integration/vulnerabilities/statuses_test.rb`
Expected: FAIL — `vulnerabilities_status_path` is undefined (no route yet).

- [ ] **Step 3: Add the route**

In `web/config/routes.rb`, extend the existing block:

```ruby
  namespace :vulnerabilities do
    get "/", to: "overview#index", as: :root
    patch "/:id/status", to: "statuses#update", as: :status
  end
```

- [ ] **Step 4: Create the controller**

Create `web/app/controllers/vulnerabilities/statuses_controller.rb`:

```ruby
module Vulnerabilities
  # Handles inline status edits from the findings table. Writes through the
  # module's MongoSource and answers with a Turbo Stream that swaps the row's
  # status cell. Kept separate from OverviewController so listing stays focused.
  class StatusesController < BaseController
    def update
      doc = MongoSource.update_status(id: params[:id], status: params[:status], user: Current.user)
      return head :not_found unless doc

      @finding = ::Vulnerability.new(doc)
      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to vulnerabilities_root_path }
      end
    rescue ArgumentError
      head :bad_request
    end
  end
end
```

- [ ] **Step 5: Create the Turbo Stream view**

Create `web/app/views/vulnerabilities/statuses/update.turbo_stream.erb`:

```erb
<%= turbo_stream.replace "status_cell_#{@finding.id}" do %>
  <td id="status_cell_<%= @finding.id %>" class="px-4 py-3">
    <%= render "vulnerabilities/overview/status_badge", finding: @finding %>
  </td>
<% end %>
```

- [ ] **Step 6: Rewrite the status badge partial as an auto-submitting select**

Replace the entire contents of `web/app/views/vulnerabilities/overview/_status_badge.html.erb`:

```erb
<%= form_with url: vulnerabilities_status_path(finding.id), method: :patch,
      data: { controller: "status-select" } do |f| %>
  <%= f.select :status,
        status_select_options,
        { selected: display_status(finding.report["status"]) },
        class: "rounded border border-zinc-300 bg-white px-2 py-0.5 text-xs font-medium text-zinc-600 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-300",
        data: { action: "change->status-select#submit" } %>
<% end %>
```

Note: `form_with` defaults to Turbo, so the submit is sent as a Turbo Stream request and matched by `format.turbo_stream`.

- [ ] **Step 7: Point the finding row at the new partial with a stable cell id**

In `web/app/views/vulnerabilities/overview/_finding_row.html.erb`, replace the status `<td>` (line 3) with:

```erb
  <td id="status_cell_<%= finding.id %>" class="px-4 py-3"><%= render "vulnerabilities/overview/status_badge", finding: finding %></td>
```

Leave the severity `<td>` and all other cells unchanged.

- [ ] **Step 8: Create the Stimulus controller**

Create `web/app/javascript/controllers/status_select_controller.js`:

```javascript
import { Controller } from "@hotwired/stimulus"

// Submits the status form the moment the dropdown changes — no submit button.
export default class extends Controller {
  submit() {
    this.element.requestSubmit()
  }
}
```

(No edit to `controllers/index.js` — `eagerLoadControllersFrom("controllers", ...)` auto-registers it.)

- [ ] **Step 9: Run the integration test to verify it passes**

Run: `bin/rails test test/integration/vulnerabilities/statuses_test.rb`
Expected: PASS (all four tests).

- [ ] **Step 10: Run the full suite + rebuild Tailwind**

Run: `bin/rails test`
Expected: PASS (no regressions in `overview_test.rb` or `sidebar_shell_test.rb`).

Run: `bin/rails tailwindcss:build`
Expected: builds `app/assets/builds/tailwind.css` with no errors; the new severity color classes are present. (App is run in Docker by the user for a live visual check.)

- [ ] **Step 11: Commit**

```bash
git -c user.name="Claude" -c user.email="noreply@anthropic.com" add \
  config/routes.rb \
  app/controllers/vulnerabilities/statuses_controller.rb \
  app/views/vulnerabilities/statuses/update.turbo_stream.erb \
  app/views/vulnerabilities/overview/_status_badge.html.erb \
  app/views/vulnerabilities/overview/_finding_row.html.erb \
  app/javascript/controllers/status_select_controller.js \
  test/integration/vulnerabilities/statuses_test.rb
git -c user.name="Claude" -c user.email="noreply@anthropic.com" \
  commit -m "Make vulnerability status editable inline via an auto-submitting dropdown and Turbo Stream"
```

---

## Notes for the implementer

- **Auth:** the vulnerabilities web department redirects unauthenticated requests to `new_session_path` (see `overview_test.rb`). That is why the unauthenticated status test asserts a redirect, not a 401 — the 401 envelope belongs to the JSON API, which this endpoint is not.
- **Why the service references a view helper constant:** `VulnerabilitiesHelper::STATUSES` is the single source of truth for the vocabulary. If a service→helper reference bothers you, lift `STATUSES` into a small shared constant both read — but keep exactly one definition.
- **No live Mongo:** every test doubles `MongoSource.collection` or stubs `MongoSource` methods with `stub_methods`. Do not add fixtures that hit Mongo.
```
