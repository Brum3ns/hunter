# Hunter Settings — Runner Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Runners" section to the Settings page where a signed-in user can list, mint (token shown once), and permanently revoke runner identities.

**Architecture:** Reuse the existing `Runner` model + `Runner.generate` (random token, SHA-256 digest stored, raw returned once). A settings-scoped `Settings::RunnersController` handles create/destroy; `SettingsController#show` lists runners and renders the create form + one-time token banner. Permanent delete uses `has_many :runner_jobs, dependent: :nullify` so past jobs survive with a null runner link.

**Tech Stack:** Rails 8, Postgres, Tailwind v4, Hotwire (Turbo + the existing `clipboard` Stimulus controller), Minitest.

## Global Constraints

- Ruby 3.3.6, Rails 8, module namespace `Hunter`; app lives in `web/`.
- No admin role exists — settings is behind the app's existing sign-in auth; every signed-in user can manage runners.
- The runner container reads its token from env (`RUNNER_TOKEN`); the UI cannot push it — this is unchanged.
- Tests must not hit live Mongo/runner/network; Postgres `hunter_test` required (tests run in Docker). Use the `sign_in_as(user)` helper and `users(:one)` fixture already used by other integration tests.
- Commit author `Claude <noreply@anthropic.com>`; one-sentence commit messages; commit only when the user asks.

---

### Task 1: `Runner` model — job nullify + kinds presence

**Files:**
- Modify: `web/app/models/runner.rb`
- Test: `web/test/models/runner_test.rb`

**Interfaces:**
- Consumes: existing `Runner.generate(name:, kinds:) -> [Runner, String]`, `RunnerJob` (existing).
- Produces: `Runner#runner_jobs` association; `Runner` now invalid when `kinds` is empty.

- [ ] **Step 1: Write the failing tests** — append to `web/test/models/runner_test.rb` (inside the class):

```ruby
  test "destroying a runner nullifies its jobs but keeps them" do
    runner, = Runner.generate(name: "curl-runner", kinds: %w[curl])
    user = users(:one)
    job = RunnerJob.create!(kind: "curl", command: "curl https://x", vulnerability_id: "v",
                            requested_by: user, status: "running", runner: runner, started_at: Time.current)
    runner.destroy
    assert RunnerJob.exists?(job.id), "job should survive runner deletion"
    assert_nil job.reload.runner_id
  end

  test "kinds must be present" do
    assert_raises(ActiveRecord::RecordInvalid) { Runner.generate(name: "empty", kinds: []) }
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd web && bin/rails test test/models/runner_test.rb`
Expected: FAIL — deleting a runner with a job raises a FK violation (no nullify); empty kinds is currently allowed.

- [ ] **Step 3: Implement** — add these two lines to `web/app/models/runner.rb` after the existing `validates` lines:

```ruby
  has_many :runner_jobs, dependent: :nullify
  validates :kinds, presence: true
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd web && bin/rails test test/models/runner_test.rb`
Expected: PASS (all tests, including the pre-existing ones).

- [ ] **Step 5: Commit** (only when the user asks)

```bash
cd web && git -c user.name=Claude -c user.email=noreply@anthropic.com add app/models/runner.rb test/models/runner_test.rb
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Nullify runner jobs on runner delete and require runner kinds"
```

---

### Task 2: Routes + controllers — list/create/destroy

**Files:**
- Modify: `web/config/routes.rb`
- Modify: `web/app/controllers/settings_controller.rb`
- Create: `web/app/controllers/settings/runners_controller.rb`
- Test: `web/test/integration/settings/runners_test.rb`
- Test: `web/test/integration/settings_test.rb`

**Interfaces:**
- Consumes: `Runner.generate` (Task 1), `Runner`, `RunnerJob`, `settings_path` (existing).
- Produces: `settings_runners_path` (POST), `settings_runner_path(runner)` (DELETE); `@runners` for the view; `flash[:runner_token]` / `flash[:runner_name]` set once on successful create.

- [ ] **Step 1: Write the failing tests**

Create `web/test/integration/settings/runners_test.rb`:

```ruby
require "test_helper"

class Settings::RunnersTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }

  test "unauthenticated create redirects to sign in" do
    post settings_runners_path, params: { name: "r", kinds: ["curl"] }
    assert_response :redirect
    assert_equal 0, Runner.count
  end

  test "unauthenticated destroy redirects and keeps the runner" do
    runner, = Runner.generate(name: "r", kinds: %w[curl])
    delete settings_runner_path(runner)
    assert_response :redirect
    assert Runner.exists?(runner.id)
  end

  test "create mints a runner and exposes the raw token once (digest stored)" do
    sign_in_as(@user)
    assert_difference -> { Runner.count }, 1 do
      post settings_runners_path, params: { name: "curl-runner", kinds: ["curl"] }
    end
    assert_redirected_to settings_path
    token = flash[:runner_token]
    assert token.present?
    runner = Runner.find_by!(name: "curl-runner")
    assert_equal %w[curl], runner.kinds
    assert_not_equal token, runner.token_digest
    assert_equal Digest::SHA256.hexdigest(token), runner.token_digest
  end

  test "duplicate name shows an alert and mints nothing" do
    sign_in_as(@user)
    Runner.generate(name: "dup", kinds: %w[curl])
    assert_no_difference -> { Runner.count } do
      post settings_runners_path, params: { name: "dup", kinds: ["curl"] }
    end
    assert_redirected_to settings_path
    assert flash[:alert].present?
  end

  test "no kinds shows an alert and mints nothing" do
    sign_in_as(@user)
    assert_no_difference -> { Runner.count } do
      post settings_runners_path, params: { name: "nokinds" }
    end
    assert flash[:alert].present?
  end

  test "destroy revokes the runner and nullifies its jobs" do
    sign_in_as(@user)
    runner, = Runner.generate(name: "r", kinds: %w[curl])
    job = RunnerJob.create!(kind: "curl", command: "curl https://x", vulnerability_id: "v",
                            requested_by: @user, status: "running", runner: runner, started_at: Time.current)
    delete settings_runner_path(runner)
    assert_redirected_to settings_path
    refute Runner.exists?(runner.id)
    assert RunnerJob.exists?(job.id)
    assert_nil job.reload.runner_id
  end
end
```

Create `web/test/integration/settings_test.rb`:

```ruby
require "test_helper"

class SettingsTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }

  test "unauthenticated settings redirects to sign in" do
    get settings_path
    assert_response :redirect
  end

  test "settings lists runners" do
    sign_in_as(@user)
    Runner.generate(name: "curl-runner", kinds: %w[curl])
    get settings_path
    assert_response :success
    assert_includes @response.body, "curl-runner"
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd web && bin/rails test test/integration/settings/runners_test.rb test/integration/settings_test.rb`
Expected: FAIL — `settings_runners_path` undefined / controller missing.

- [ ] **Step 3: Implement routes + controllers**

In `web/config/routes.rb`, add directly after the `get "settings", ...` line:

```ruby
  namespace :settings do
    resources :runners, only: %i[create destroy]
  end
```

Replace `web/app/controllers/settings_controller.rb` with:

```ruby
class SettingsController < ApplicationController
  def show
    @runners = Runner.order(:name)
  end
end
```

Create `web/app/controllers/settings/runners_controller.rb`:

```ruby
module Settings
  class RunnersController < ApplicationController
    def create
      kinds = Array(params[:kinds]).map { |k| k.to_s.strip }.reject(&:blank?)
      runner, raw = Runner.generate(name: params[:name].to_s.strip, kinds: kinds)
      flash[:runner_token] = raw
      flash[:runner_name] = runner.name
      redirect_to settings_path, notice: "Runner “#{runner.name}” created."
    rescue ActiveRecord::RecordInvalid => e
      redirect_to settings_path, alert: e.record.errors.full_messages.to_sentence
    end

    def destroy
      Runner.find(params[:id]).destroy
      redirect_to settings_path, notice: "Runner revoked."
    end
  end
end
```

Note: `ApplicationController` already enforces sign-in via the Rails 8 authentication concern (same gate that protects the existing `settings#show`). Verify it does before running — if `settings#show` is currently reachable unauthenticated, add the authentication `before_action` to these controllers. (Check: `grep -rn "require_authentication\|allow_unauthenticated" app/controllers/application_controller.rb app/controllers/concerns`.)

- [ ] **Step 4: Run to verify it passes**

Run: `cd web && bin/rails test test/integration/settings/runners_test.rb test/integration/settings_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit** (only when the user asks)

```bash
cd web && git -c user.name=Claude -c user.email=noreply@anthropic.com add config/routes.rb app/controllers/settings_controller.rb app/controllers/settings/runners_controller.rb test/integration/settings
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Add settings runner list/create/revoke endpoints"
```

---

### Task 3: Settings view — Runners section UI

**Files:**
- Modify: `web/app/views/settings/show.html.erb`

**Interfaces:**
- Consumes: `@runners` (Task 2), `settings_runners_path`/`settings_runner_path` (Task 2), `flash[:runner_token]`/`flash[:runner_name]`, `RunnerJob::KINDS`, `heroicon` helper, the `clipboard` Stimulus controller (targets `source`/`button`, action `clipboard#copy`), `time_ago_in_words`.
- Produces: the rendered Settings UI (verified live).

- [ ] **Step 1: Replace `web/app/views/settings/show.html.erb`** with:

```erb
<% content_for :title, "hunter — Settings" %>
<div class="mx-auto max-w-3xl">
  <h1 class="text-2xl font-semibold text-zinc-900 dark:text-zinc-100">Settings</h1>

  <% if notice.present? %>
    <div class="mt-4 rounded-md bg-emerald-50 px-3 py-2 text-sm text-emerald-700 ring-1 ring-inset ring-emerald-600/20 dark:bg-emerald-500/10 dark:text-emerald-300 dark:ring-emerald-400/20"><%= notice %></div>
  <% end %>
  <% if alert.present? %>
    <div class="mt-4 rounded-md bg-rose-50 px-3 py-2 text-sm text-rose-700 ring-1 ring-inset ring-rose-600/20 dark:bg-rose-500/10 dark:text-rose-300 dark:ring-rose-400/20"><%= alert %></div>
  <% end %>

  <section class="mt-8">
    <h2 class="text-sm font-semibold uppercase tracking-wider text-zinc-500 dark:text-zinc-400">Runners</h2>
    <p class="mt-1 text-sm text-zinc-500 dark:text-zinc-400">
      Machine identities that pull and execute jobs. After creating one, put its token in the runner
      container's <code class="rounded bg-zinc-100 px-1 py-0.5 text-xs dark:bg-zinc-800">RUNNER_TOKEN</code>
      env var and restart it — the token can't be pushed from here.
    </p>

    <% if flash[:runner_token].present? %>
      <div class="mt-4 rounded-lg border border-amber-300 bg-amber-50 p-3 dark:border-amber-400/30 dark:bg-amber-500/10">
        <p class="text-sm font-medium text-amber-800 dark:text-amber-200">
          Token for “<%= flash[:runner_name] %>” — copy it now, it is shown once and cannot be retrieved later.
        </p>
        <div data-controller="clipboard" class="mt-2 flex items-center gap-2 overflow-hidden rounded-md border border-amber-300/60 bg-white px-3 py-2 dark:border-amber-400/20 dark:bg-zinc-950">
          <code data-clipboard-target="source" class="flex-1 truncate font-mono text-xs text-zinc-800 dark:text-zinc-100"><%= flash[:runner_token] %></code>
          <button type="button" data-action="clipboard#copy" data-clipboard-target="button"
                  class="inline-flex flex-none items-center gap-1 rounded px-1.5 py-0.5 text-[11px] font-medium text-zinc-500 hover:bg-zinc-100 hover:text-zinc-800 dark:text-zinc-400 dark:hover:bg-zinc-800 dark:hover:text-zinc-100">
            <%= heroicon "clipboard-document-list", classes: "h-3.5 w-3.5" %> Copy
          </button>
        </div>
      </div>
    <% end %>

    <%= form_with url: settings_runners_path, method: :post, class: "mt-4 flex flex-wrap items-end gap-3" do %>
      <div class="flex flex-col gap-1">
        <label for="runner_name" class="text-xs font-medium text-zinc-600 dark:text-zinc-400">Name</label>
        <input type="text" name="name" id="runner_name" placeholder="curl-runner"
               class="rounded-md border border-zinc-300 bg-white px-2.5 py-1.5 text-sm text-zinc-900 shadow-sm focus:border-zinc-500 focus:outline-none dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-100">
      </div>
      <div class="flex flex-col gap-1">
        <span class="text-xs font-medium text-zinc-600 dark:text-zinc-400">Kinds</span>
        <div class="flex items-center gap-3 py-1.5">
          <% RunnerJob::KINDS.each do |kind| %>
            <label class="inline-flex items-center gap-1.5 text-sm text-zinc-700 dark:text-zinc-300">
              <input type="checkbox" name="kinds[]" value="<%= kind %>" <%= "checked" if kind == "curl" %>
                     class="rounded border-zinc-300 dark:border-zinc-700">
              <%= kind %>
            </label>
          <% end %>
        </div>
      </div>
      <button type="submit"
              class="inline-flex items-center gap-1.5 rounded-md bg-zinc-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-zinc-700 dark:bg-white dark:text-zinc-900 dark:hover:bg-zinc-200">
        Create runner
      </button>
    <% end %>

    <div class="mt-6 overflow-hidden rounded-lg border border-zinc-200 dark:border-zinc-800">
      <table class="w-full text-left text-sm">
        <thead class="border-b border-zinc-200 bg-zinc-50 text-xs uppercase tracking-wide text-zinc-500 dark:border-zinc-800 dark:bg-zinc-900/60 dark:text-zinc-400">
          <tr>
            <th class="px-3 py-2 font-medium">Name</th>
            <th class="px-3 py-2 font-medium">Kinds</th>
            <th class="px-3 py-2 font-medium">Last seen</th>
            <th class="px-3 py-2 font-medium">Created</th>
            <th class="px-3 py-2"></th>
          </tr>
        </thead>
        <tbody class="divide-y divide-zinc-100 dark:divide-zinc-800/70">
          <% if @runners.empty? %>
            <tr><td colspan="5" class="px-3 py-4 text-center text-zinc-500 dark:text-zinc-400">No runners yet.</td></tr>
          <% else %>
            <% @runners.each do |runner| %>
              <tr>
                <td class="px-3 py-2 font-medium text-zinc-800 dark:text-zinc-200"><%= runner.name %></td>
                <td class="px-3 py-2 text-zinc-600 dark:text-zinc-400"><%= runner.kinds.join(", ") %></td>
                <td class="px-3 py-2 text-zinc-600 dark:text-zinc-400"><%= runner.last_seen_at ? "#{time_ago_in_words(runner.last_seen_at)} ago" : "never" %></td>
                <td class="px-3 py-2 text-zinc-600 dark:text-zinc-400"><%= runner.created_at.to_date.iso8601 %></td>
                <td class="px-3 py-2 text-right">
                  <%= button_to settings_runner_path(runner), method: :delete,
                        class: "text-xs font-medium text-rose-600 hover:text-rose-500 dark:text-rose-400",
                        form: { data: { turbo_confirm: "Revoke #{runner.name}? Its token stops working immediately." } } do %>
                    Revoke
                  <% end %>
                </td>
              </tr>
            <% end %>
          <% end %>
        </tbody>
      </table>
    </div>
  </section>
</div>
```

- [ ] **Step 2: Verify the settings show test still passes**

Run: `cd web && bin/rails test test/integration/settings_test.rb`
Expected: PASS.

- [ ] **Step 3: Verify live** (the running dev app volume-mounts `web/`, so edits reload)

- Load `/settings` in the browser (signed in). Confirm the Runners section, empty state, and create form render.
- Create a runner (name `curl-runner`, curl checked) → the one-time token banner appears with a Copy button; the runner shows in the table with "last seen: never".
- Reload `/settings` → the token banner is gone (flash consumed), the runner remains.
- Revoke the runner → confirm dialog, then it disappears and a notice shows.

- [ ] **Step 4: Commit** (only when the user asks)

```bash
cd web && git -c user.name=Claude -c user.email=noreply@anthropic.com add app/views/settings/show.html.erb
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Build the settings runners management UI"
```

---

## Self-Review

**Spec coverage:** list/create/revoke → Tasks 2+3; token-once (flash banner) → Tasks 2+3; permanent delete keeping job history (`dependent: :nullify`) → Task 1; kinds presence (the spec's deferred "Open decision", defaulted to enforce) → Task 1; auth inherited + unauth redirect tested → Task 2; operator note about `RUNNER_TOKEN` → Task 3; tests enumerated (model, controller, show) → all tasks. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code. The only external check is the `ApplicationController` auth verification, written as an explicit grep, not a placeholder. ✓

**Type consistency:** `Runner.generate(name:, kinds:)`, `settings_runners_path`/`settings_runner_path`, `flash[:runner_token]`/`flash[:runner_name]`, `RunnerJob::KINDS`, and `@runners` are used identically across tasks. `has_many :runner_jobs` matches `RunnerJob belongs_to :runner` (fk `runner_id`). ✓
