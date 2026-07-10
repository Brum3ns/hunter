# Hunter Strict Per-Module Structure & Generator — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reorganize Hunter so every section is a strictly isolated module (API + service + model + tabbed web department) and ship a Rails generator that scaffolds a new module in one command.

**Architecture:** Migrate the existing vulnerability-management module into the strict per-module shape (it becomes the canonical reference), then build a `hunter:module` generator whose templates reproduce that shape. Adding a module edits only two shared files (routes + sidebar nav), both written by the generator.

**Tech Stack:** Ruby 3.3.6, Rails 8, Minitest, importmap/Stimulus, Tailwind v4, MongoDB (`HunterMongo`), PostgreSQL.

## Global Constraints

- **DO NOT COMMIT.** The user holds all commit approval until they explicitly say "go". Each task's final step is `git add` (staging) only — never `git commit`.
- Commit author, when eventually allowed: `Claude <noreply@anthropic.com>`; one-sentence message.
- Tests run from `web/`: `bin/rails test`. Needs a reachable Postgres `hunter_test`. Mongo is **doubled** in tests via the `stub_methods` helper (`test/test_helper.rb`) — no live Mongo.
- Ruby namespace is `Hunter`; module sections are lower_snake (`vulnerabilities`), primary resources are singular (`finding`).
- API URL shape is `/api/v1/<module>/<resource>`. This pass changes `/api/v1/vulnerabilities` → `/api/v1/vulnerabilities/findings`.
- Reads in `MongoSource` swallow `Mongo::Error` to empty results; writes let it raise (controller maps to 502).
- Do not modify `HunterMongo`, `Api::BaseController`, `Api::V1::BaseController` responsibilities, the `Vulnerability` PORO, or its model test.

---

### Task 1: Migrate the vulnerabilities API into a module namespace

**Files:**
- Create: `web/app/controllers/api/v1/vulnerabilities/base_controller.rb`
- Create: `web/app/controllers/api/v1/vulnerabilities/findings_controller.rb`
- Delete: `web/app/controllers/api/v1/vulnerabilities_controller.rb`
- Modify: `web/config/routes.rb` (API block)
- Create: `web/test/integration/api/v1/vulnerabilities/findings_test.rb`
- Delete: `web/test/integration/api/v1/vulnerabilities_test.rb`

**Interfaces:**
- Consumes: `Vulnerabilities::MongoSource` (`.all(filters:,page:,limit:)`, `.count(filters:)`, `.find(id)`, `.create(attrs)`, `.update(id,attrs)`, `.delete(id)`); `Vulnerability.new(doc).as_json`.
- Produces: route `/api/v1/vulnerabilities/findings` (`Api::V1::Vulnerabilities::FindingsController`); index JSON key renamed `vulnerabilities` → `findings`; per-module API base `Api::V1::Vulnerabilities::BaseController < Api::V1::BaseController`.

- [ ] **Step 1: Relocate the API integration test (failing — paths don't exist yet)**

Create `web/test/integration/api/v1/vulnerabilities/findings_test.rb` and delete the old `web/test/integration/api/v1/vulnerabilities_test.rb`. New file:

```ruby
require "test_helper"

class Api::V1::Vulnerabilities::FindingsTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }

  Source = Vulnerabilities::MongoSource

  test "returns 401 without a cookie or token" do
    get "/api/v1/vulnerabilities/findings"
    assert_response :unauthorized
    assert_equal "unauthorized", JSON.parse(response.body)["error"]
  end

  test "index works for a cookie-authenticated user" do
    sign_in_as(@user)
    stub_methods(Source, all: [{ "id" => "1", "finding" => {} }], count: 1) do
      get "/api/v1/vulnerabilities/findings"
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal 1, body["count"]
      assert_equal 1, body["findings"].length
    end
  end

  test "index authenticates via a bearer token" do
    _record, raw = ApiToken.generate(user: @user, name: "ci")
    stub_methods(Source, all: [], count: 0) do
      get "/api/v1/vulnerabilities/findings", headers: { "Authorization" => "Bearer #{raw}" }
      assert_response :success
    end
  end

  test "index passes filters through and clamps the limit" do
    sign_in_as(@user)
    captured = nil
    capture = ->(filters:, page:, limit:) { captured = { filters: filters, page: page, limit: limit }; [] }

    stub_methods(Source, all: capture, count: 0) do
      get "/api/v1/vulnerabilities/findings", params: { severity: "high", page: "3", limit: "9999" }
    end

    assert_equal({ "severity" => "high" }, captured[:filters])
    assert_equal 3, captured[:page]
    assert_equal 200, captured[:limit]
  end

  test "show returns the document or 404" do
    sign_in_as(@user)
    stub_methods(Source, find: { "id" => "abc", "finding" => { "name" => "X" } }) do
      get "/api/v1/vulnerabilities/findings/abc"
      assert_response :success
      assert_equal "abc", JSON.parse(response.body)["id"]
    end

    stub_methods(Source, find: nil) do
      get "/api/v1/vulnerabilities/findings/missing"
      assert_response :not_found
    end
  end

  test "create inserts the body and returns 201 with the new id" do
    sign_in_as(@user)
    stub_methods(Source, create: "new-id") do
      post "/api/v1/vulnerabilities/findings", params: { finding: { name: "x" } }, as: :json
      assert_response :created
      assert_equal "new-id", JSON.parse(response.body)["id"]
    end
  end

  test "update returns the updated document or 404" do
    sign_in_as(@user)
    stub_methods(Source, update: { "id" => "abc", "report" => { "status" => "triaged" } }) do
      patch "/api/v1/vulnerabilities/findings/abc", params: { report: { status: "triaged" } }, as: :json
      assert_response :success
      assert_equal "triaged", JSON.parse(response.body).dig("report", "status")
    end

    stub_methods(Source, update: nil) do
      patch "/api/v1/vulnerabilities/findings/missing", params: {}, as: :json
      assert_response :not_found
    end
  end

  test "destroy returns 204 on success and 404 when absent" do
    sign_in_as(@user)
    stub_methods(Source, delete: true) do
      delete "/api/v1/vulnerabilities/findings/abc"
      assert_response :no_content
    end

    stub_methods(Source, delete: false) do
      delete "/api/v1/vulnerabilities/findings/missing"
      assert_response :not_found
    end
  end

  test "maps a Mongo write failure to 502" do
    sign_in_as(@user)
    stub_methods(Source, create: ->(*) { raise Mongo::Error.new("down") }) do
      post "/api/v1/vulnerabilities/findings", params: { finding: {} }, as: :json
      assert_response :bad_gateway
      assert_equal "upstream_unavailable", JSON.parse(response.body)["error"]
    end
  end
end
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `cd web && bin/rails test test/integration/api/v1/vulnerabilities/findings_test.rb`
Expected: FAIL — routing errors for `/api/v1/vulnerabilities/findings` (no route).

- [ ] **Step 3: Create the per-module API base controller**

`web/app/controllers/api/v1/vulnerabilities/base_controller.rb`:

```ruby
module Api
  module V1
    module Vulnerabilities
      # Per-module API base. Auth/CSRF/JSON/errors come from Api::BaseController;
      # pagination + render_not_found from Api::V1::BaseController. Module-local
      # API hooks (shared filters, serializers) belong here.
      class BaseController < Api::V1::BaseController
      end
    end
  end
end
```

- [ ] **Step 4: Create the findings controller (moved from the flat file)**

`web/app/controllers/api/v1/vulnerabilities/findings_controller.rb`:

```ruby
module Api
  module V1
    module Vulnerabilities
      # Findings API — full CRUD over the MongoDB `vulnerabilities` collection.
      # No document-shape validation this pass; any well-formed JSON is accepted.
      class FindingsController < BaseController
        # GET /api/v1/vulnerabilities/findings
        def index
          filters = filter_params
          page = pagination_page
          limit = clamped_limit

          docs = ::Vulnerabilities::MongoSource.all(filters: filters, page: page, limit: limit)
          render json: {
            count: ::Vulnerabilities::MongoSource.count(filters: filters),
            page: page,
            limit: limit,
            findings: docs.map { |doc| serialize(doc) }
          }
        end

        # GET /api/v1/vulnerabilities/findings/:id
        def show
          doc = ::Vulnerabilities::MongoSource.find(params[:id])
          return render_not_found unless doc

          render json: serialize(doc)
        end

        # POST /api/v1/vulnerabilities/findings
        def create
          id = ::Vulnerabilities::MongoSource.create(document_params)
          render json: { id: id }, status: :created
        end

        # PATCH/PUT /api/v1/vulnerabilities/findings/:id
        def update
          doc = ::Vulnerabilities::MongoSource.update(params[:id], document_params)
          return render_not_found unless doc

          render json: serialize(doc)
        end

        # DELETE /api/v1/vulnerabilities/findings/:id
        def destroy
          return head(:no_content) if ::Vulnerabilities::MongoSource.delete(params[:id])

          render_not_found
        end

        private

        def filter_params
          params.permit(:program, :severity, :status, :tool).to_h
        end

        # The whole JSON body, minus routing/id noise. No validation this pass.
        def document_params
          params.except(:controller, :action, :format, :id, :finding).permit!.to_h
        end

        def serialize(doc)
          Vulnerability.new(doc).as_json
        end
      end
    end
  end
end
```

Note: the `::` prefix on `Vulnerabilities::MongoSource` and the top-level `Vulnerability` PORO avoids resolving into the new `Api::V1::Vulnerabilities` namespace. `document_params` excludes `:finding` (the wrapper key the test posts under).

Then delete `web/app/controllers/api/v1/vulnerabilities_controller.rb`.

- [ ] **Step 5: Update the API routes**

In `web/config/routes.rb`, replace:

```ruby
    namespace :v1 do
      # Vulnerability management module.
      resources :vulnerabilities, only: %i[index show create update destroy]
    end
```

with:

```ruby
    namespace :v1 do
      # Vulnerability management module.
      namespace :vulnerabilities do
        resources :findings, only: %i[index show create update destroy]
      end
    end
```

- [ ] **Step 6: Run the test, verify it passes**

Run: `cd web && bin/rails test test/integration/api/v1/vulnerabilities/findings_test.rb`
Expected: PASS (all assertions).

- [ ] **Step 7: Stage (do not commit)**

```bash
cd web && git add app/controllers/api/v1/vulnerabilities/ test/integration/api/v1/vulnerabilities/ config/routes.rb && git rm app/controllers/api/v1/vulnerabilities_controller.rb test/integration/api/v1/vulnerabilities_test.rb
```

---

### Task 2: Migrate the vulnerabilities web department into a tabbed namespace

**Files:**
- Create: `web/app/controllers/concerns/department.rb`
- Create: `web/app/controllers/vulnerabilities/base_controller.rb`
- Create: `web/app/controllers/vulnerabilities/overview_controller.rb`
- Delete: `web/app/controllers/vulnerabilities_controller.rb`
- Create: `web/app/views/vulnerabilities/overview/index.html.erb`
- Create: `web/app/views/vulnerabilities/_subnav.html.erb`
- Delete: `web/app/views/vulnerabilities/index.html.erb`
- Modify: `web/config/routes.rb` (web block)
- Modify: `web/app/helpers/navigation_helper.rb`
- Modify: `web/test/helpers/navigation_helper_test.rb`
- Modify: `web/test/integration/sidebar_shell_test.rb`

**Interfaces:**
- Consumes: `ApplicationController`; `heroicon` helper; sidebar partials.
- Produces: `Department` concern (`helper_method :section_tabs, :section_tab_active?`); `Vulnerabilities::BaseController` (`TABS` constant); web route helper `vulnerabilities_root_path`; updated `nav_active?` matching namespaced controllers via `controller_path`.

- [ ] **Step 1: Update the sidebar shell test to the new helper + namespaced active state (failing)**

In `web/test/integration/sidebar_shell_test.rb`, change `vulnerabilities_path` to `vulnerabilities_root_path` in both the link assertion and the active-section test:

```ruby
  test "renders the sidebar with all nav links" do
    get root_path
    assert_select "[data-controller=sidebar] aside[data-sidebar-target=aside]", count: 1
    assert_select "a[href=?]", root_path
    assert_select "a[href=?]", programs_path
    assert_select "a[href=?]", vulnerabilities_root_path
    assert_select "a[href=?]", control_center_path
    assert_select "a[href=?]", cves_path
    assert_select "a[href=?]", settings_path
    assert_select "a[href=?]", help_path
  end

  test "highlights the active section" do
    get vulnerabilities_root_path
    assert_select "a[href=?][aria-current=page]", vulnerabilities_root_path
    assert_select "a[href=?]:not([aria-current])", programs_path
  end
```

- [ ] **Step 2: Add a navigation_helper unit test for namespaced matching (failing)**

Append to `web/test/helpers/navigation_helper_test.rb`:

```ruby
  test "matches a namespaced controller against its module" do
    def controller_path = "vulnerabilities/overview"
    def controller_name = "overview"
    assert nav_active?("vulnerabilities")
  end
```

- [ ] **Step 3: Run both tests, verify they fail**

Run: `cd web && bin/rails test test/integration/sidebar_shell_test.rb test/helpers/navigation_helper_test.rb`
Expected: FAIL — `vulnerabilities_root_path` undefined and namespaced match unimplemented.

- [ ] **Step 4: Create the Department concern**

`web/app/controllers/concerns/department.rb`:

```ruby
# Shared behavior for a web "department" (a Hunter module's UI section). Each
# department's BaseController includes this and defines a TABS constant; the
# concern exposes the tab list + active-tab test to that module's _subnav.
module Department
  extend ActiveSupport::Concern

  included do
    helper_method :section_tabs, :section_tab_active?
  end

  # [{ label:, path: }, ...] for the current section, from the controller's TABS.
  def section_tabs
    self.class.const_defined?(:TABS) ? self.class::TABS : []
  end

  def section_tab_active?(path)
    request.path == path
  end
end
```

- [ ] **Step 5: Create the vulnerabilities web base + overview controllers**

`web/app/controllers/vulnerabilities/base_controller.rb`:

```ruby
module Vulnerabilities
  # Web department base for the vulnerability-management section. Declares the
  # in-section tabs; per-tab controllers subclass this. Auth comes from
  # ApplicationController.
  class BaseController < ApplicationController
    include Department

    TABS = [
      { label: "Overview", path: "/vulnerabilities" }
    ].freeze
  end
end
```

`web/app/controllers/vulnerabilities/overview_controller.rb`:

```ruby
module Vulnerabilities
  class OverviewController < BaseController
    def index
    end
  end
end
```

Then delete `web/app/controllers/vulnerabilities_controller.rb`.

- [ ] **Step 6: Move the view and add the subnav partial**

Create `web/app/views/vulnerabilities/overview/index.html.erb`:

```erb
<% content_for :title, "hunter — Vulnerabilities" %>
<%= render "vulnerabilities/subnav" %>
<h1 class="text-2xl font-semibold text-zinc-900 dark:text-zinc-100">Vulnerabilities</h1>
<p class="mt-2 text-zinc-500 dark:text-zinc-400">Vulnerability findings are coming soon.</p>
```

Create `web/app/views/vulnerabilities/_subnav.html.erb`:

```erb
<%# In-section tabs, rendered from the department's TABS via the Department concern. %>
<nav class="mb-4 flex gap-4 border-b border-zinc-200 dark:border-white/10">
  <% section_tabs.each do |tab| %>
    <%= link_to tab[:label], tab[:path],
          class: "border-b-2 px-1 pb-2 text-sm #{section_tab_active?(tab[:path]) ? 'border-zinc-900 text-zinc-900 dark:border-zinc-100 dark:text-zinc-100' : 'border-transparent text-zinc-500 hover:text-zinc-700 dark:text-zinc-400'}",
          'aria-current': (section_tab_active?(tab[:path]) ? 'page' : nil) %>
  <% end %>
</nav>
```

Then delete `web/app/views/vulnerabilities/index.html.erb`.

- [ ] **Step 7: Update the web routes**

In `web/config/routes.rb`, replace `get "vulnerabilities", to: "vulnerabilities#index"` with:

```ruby
  namespace :vulnerabilities do
    get "/", to: "overview#index", as: :root
  end
```

This yields the `vulnerabilities_root_path` helper.

- [ ] **Step 8: Update nav_active? and the sidebar nav entry**

In `web/app/helpers/navigation_helper.rb`, replace `nav_active?`:

```ruby
  def nav_active?(*controller_names)
    names = controller_names.flatten
    return true if names.include?(controller_name)
    # Namespaced module controllers (e.g. "vulnerabilities/overview") match on
    # their leading path segment.
    segment = controller_path.split("/").first
    names.include?(segment)
  end
```

And change the Vulnerabilities entry in `primary_nav_groups`:

```ruby
        { label: "Vulnerabilities", path: vulnerabilities_root_path, controllers: %w[vulnerabilities], icon: "shield-exclamation" },
```

- [ ] **Step 9: Run the tests, verify they pass**

Run: `cd web && bin/rails test test/integration/sidebar_shell_test.rb test/helpers/navigation_helper_test.rb`
Expected: PASS.

- [ ] **Step 10: Run the full suite**

Run: `cd web && bin/rails test`
Expected: PASS (all). Confirms the migration broke nothing.

- [ ] **Step 11: Stage (do not commit)**

```bash
cd web && git add app/controllers/concerns/department.rb app/controllers/vulnerabilities/ app/views/vulnerabilities/ config/routes.rb app/helpers/navigation_helper.rb test/helpers/navigation_helper_test.rb test/integration/sidebar_shell_test.rb && git rm app/controllers/vulnerabilities_controller.rb app/views/vulnerabilities/index.html.erb
```

---

### Task 3: Build the `hunter:module` generator

**Files:**
- Create: `web/lib/generators/hunter/module/module_generator.rb`
- Create: `web/lib/generators/hunter/module/USAGE`
- Create templates (`.tt`) under `web/lib/generators/hunter/module/templates/`:
  - `service.rb.tt`, `model.rb.tt`
  - `api_base_controller.rb.tt`, `api_resources_controller.rb.tt`
  - `web_base_controller.rb.tt`, `web_overview_controller.rb.tt`
  - `view_index.html.erb.tt`, `subnav.html.erb.tt`
  - `service_test.rb.tt`, `api_test.rb.tt`, `model_test.rb.tt`
- Create: `web/test/lib/generators/hunter/module_generator_test.rb`

**Interfaces:**
- Consumes: `Rails::Generators::NamedBase`, `Thor::Actions`, `Rails::Generators::TestCase`.
- Produces: `bin/rails g hunter:module <name> --resource=<singular>` creating the full module shape + inserting routes (web + api) and a sidebar nav entry.

- [ ] **Step 1: Write the generator test (failing)**

`web/test/lib/generators/hunter/module_generator_test.rb`:

```ruby
require "test_helper"
require "rails/generators"
require "rails/generators/test_case"
require Rails.root.join("lib/generators/hunter/module/module_generator").to_s

class Hunter::ModuleGeneratorTest < Rails::Generators::TestCase
  tests Hunter::ModuleGenerator
  destination File.expand_path("../../../../tmp/generator_out", __dir__)
  setup :prepare_destination

  # The generator injects into routes.rb + navigation_helper.rb using the three
  # stable anchor comments below. The fixtures must contain those anchors.
  setup do
    FileUtils.mkdir_p("#{destination_root}/config")
    File.write("#{destination_root}/config/routes.rb", <<~RB)
      Rails.application.routes.draw do
        # hunter:module-routes (web)
        get "help", to: "help#index"

        namespace :api do
          namespace :v1 do
            # hunter:module-routes (api)
          end
        end
      end
    RB
    FileUtils.mkdir_p("#{destination_root}/app/helpers")
    File.write("#{destination_root}/app/helpers/navigation_helper.rb", <<~RB)
      module NavigationHelper
        def primary_nav_groups
          [
            [
              { label: "Dashboard", path: root_path, controllers: %w[dashboard], icon: "home" }
            ],
            [
              # hunter:module-nav
              { label: "CVEs", path: cves_path, controllers: %w[cves], icon: "bug-ant" }
            ]
          ]
        end
      end
    RB
  end

  test "generates the full module file set" do
    run_generator %w[github --resource=repository]

    assert_file "app/services/github/mongo_source.rb", /module Github/, /COLLECTION = ENV\.fetch\("MONGO_GITHUB_COLLECTION", "github"\)/
    assert_file "app/models/repository.rb", /class Repository/
    assert_file "app/controllers/api/v1/github/base_controller.rb", /class BaseController < Api::V1::BaseController/
    assert_file "app/controllers/api/v1/github/repositories_controller.rb", /class RepositoriesController < BaseController/, /repositories: docs/
    assert_file "app/controllers/github/base_controller.rb", /class BaseController < ApplicationController/, /include Department/
    assert_file "app/controllers/github/overview_controller.rb", /class OverviewController < BaseController/
    assert_file "app/views/github/overview/index.html.erb", /render "github\/subnav"/
    assert_file "app/views/github/_subnav.html.erb", /section_tabs/
    assert_file "test/services/github/mongo_source_test.rb"
    assert_file "test/integration/api/v1/github/repositories_test.rb", %r{/api/v1/github/repositories}
    assert_file "test/models/repository_test.rb"
  end

  test "injects routes and nav registrations" do
    run_generator %w[github --resource=repository]

    assert_file "config/routes.rb", /namespace :github do/, /resources :repositories/
    assert_file "app/helpers/navigation_helper.rb", /label: "Github"/
  end
end
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `cd web && bin/rails test test/lib/generators/hunter/module_generator_test.rb`
Expected: FAIL — `cannot load such file -- generators/hunter/module/module_generator`.

- [ ] **Step 3: Write the generator class**

`web/lib/generators/hunter/module/module_generator.rb`:

```ruby
require "rails/generators/named_base"

module Hunter
  # Scaffolds a complete, isolated Hunter module: service + model + namespaced
  # API (base + resource controller) + tabbed web department + tests, and
  # registers it in routes.rb and the sidebar nav. See USAGE.
  class ModuleGenerator < Rails::Generators::NamedBase
    source_root File.expand_path("templates", __dir__)

    class_option :resource, type: :string, default: nil,
                 desc: "Singular primary resource name (defaults to singularized module name)"

    # module name, lower_snake plural-ish as given (e.g. "github", "vulnerabilities")
    def module_slug
      file_name
    end

    def module_namespace
      module_slug.camelize # Github, Vulnerabilities
    end

    def resource_singular
      (options[:resource].presence || module_slug.singularize).underscore
    end

    def resource_plural
      resource_singular.pluralize
    end

    def resource_class
      resource_singular.camelize # Repository
    end

    def create_service
      template "service.rb.tt", "app/services/#{module_slug}/mongo_source.rb"
    end

    def create_model
      template "model.rb.tt", "app/models/#{resource_singular}.rb"
    end

    def create_api_controllers
      template "api_base_controller.rb.tt",
               "app/controllers/api/v1/#{module_slug}/base_controller.rb"
      template "api_resources_controller.rb.tt",
               "app/controllers/api/v1/#{module_slug}/#{resource_plural}_controller.rb"
    end

    def create_web_controllers
      template "web_base_controller.rb.tt",
               "app/controllers/#{module_slug}/base_controller.rb"
      template "web_overview_controller.rb.tt",
               "app/controllers/#{module_slug}/overview_controller.rb"
    end

    def create_views
      template "view_index.html.erb.tt", "app/views/#{module_slug}/overview/index.html.erb"
      template "subnav.html.erb.tt", "app/views/#{module_slug}/_subnav.html.erb"
    end

    def create_tests
      template "service_test.rb.tt", "test/services/#{module_slug}/mongo_source_test.rb"
      template "api_test.rb.tt",
               "test/integration/api/v1/#{module_slug}/#{resource_plural}_test.rb"
      template "model_test.rb.tt", "test/models/#{resource_singular}_test.rb"
    end

    def register_web_route
      inject_into_file "config/routes.rb", after: "# hunter:module-routes (web)\n" do
        <<-RUBY
  namespace :#{module_slug} do
    get "/", to: "overview#index", as: :root
  end
        RUBY
      end
    end

    def register_api_route
      inject_into_file "config/routes.rb", after: "# hunter:module-routes (api)\n" do
        <<-RUBY
      namespace :#{module_slug} do
        resources :#{resource_plural}, only: %i[index show create update destroy]
      end
        RUBY
      end
    end

    def register_nav
      entry = %Q(      { label: "#{module_namespace}", path: #{module_slug}_root_path, controllers: %w[#{module_slug}], icon: "squares-2x2" },\n)
      inject_into_file "app/helpers/navigation_helper.rb", entry, after: "# hunter:module-nav\n"
    end
  end
end
```

Note: all three injections key off stable anchor comments (`# hunter:module-routes (web)`, `# hunter:module-routes (api)`, `# hunter:module-nav`). The generator test fixtures contain them; Step 5 below adds the same anchors to the real `config/routes.rb` and `navigation_helper.rb` before the live smoke test.

- [ ] **Step 4: Write the templates**

`web/lib/generators/hunter/module/templates/service.rb.tt`:

```erb
module <%= module_namespace %>
  # Full CRUD against the MongoDB `<%= module_slug %>` collection (handle in
  # HunterMongo). Reads swallow Mongo::Error to an empty result; writes let it
  # raise so the controller can map to a 502.
  module MongoSource
    module_function

    COLLECTION = ENV.fetch("MONGO_<%= module_slug.upcase %>_COLLECTION", "<%= module_slug %>")

    INDEXES = [].freeze

    FILTER_KEYS = {}.freeze

    def all(filters: {}, page: 1, limit: 50)
      HunterMongo.ensure_indexes_once!(COLLECTION, INDEXES)
      skip = ([page.to_i, 1].max - 1) * limit
      docs = collection.find(build_filter(filters)).skip(skip).limit(limit).to_a
      docs.map { |doc| normalize(doc) }
    rescue Mongo::Error => e
      Rails.logger.warn("<%= module_namespace %>::MongoSource#all failed (#{e.class}: #{e.message})")
      []
    end

    def count(filters: {})
      collection.count_documents(build_filter(filters))
    rescue Mongo::Error => e
      Rails.logger.warn("<%= module_namespace %>::MongoSource#count failed (#{e.class}: #{e.message})")
      0
    end

    def find(id)
      oid = to_object_id(id)
      return nil unless oid
      doc = collection.find(_id: oid).first
      doc && normalize(doc)
    rescue Mongo::Error => e
      Rails.logger.warn("<%= module_namespace %>::MongoSource#find failed (#{e.class}: #{e.message})")
      nil
    end

    def create(attrs)
      collection.insert_one(strip_ids(attrs)).inserted_id.to_s
    end

    def update(id, attrs)
      oid = to_object_id(id)
      return nil unless oid
      result = collection.update_one({ _id: oid }, { "$set" => strip_ids(attrs) })
      return nil if result.matched_count.zero?
      find(id)
    end

    def delete(id)
      oid = to_object_id(id)
      return false unless oid
      collection.delete_one(_id: oid).deleted_count.positive?
    end

    def collection
      HunterMongo.collection(COLLECTION)
    end

    def build_filter(filters)
      filters.to_h.each_with_object({}) do |(key, value), mongo|
        next if value.blank?
        mongo_key = FILTER_KEYS[key.to_s]
        mongo[mongo_key] = value if mongo_key
      end
    end
    private_class_method :build_filter

    def strip_ids(attrs)
      attrs.to_h.reject { |k, _| %w[id _id].include?(k.to_s) }
    end
    private_class_method :strip_ids

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

`web/lib/generators/hunter/module/templates/model.rb.tt`:

```erb
# Plain PORO wrapping a normalized Mongo doc for the <%= module_slug %> module.
class <%= resource_class %>
  def initialize(doc = {})
    @doc = doc.to_h.transform_keys(&:to_s)
  end

  def as_json(*)
    @doc
  end
end
```

`web/lib/generators/hunter/module/templates/api_base_controller.rb.tt`:

```erb
module Api
  module V1
    module <%= module_namespace %>
      # Per-module API base. Module-local API hooks belong here; auth/CSRF/JSON/
      # errors + pagination come from the shared bases.
      class BaseController < Api::V1::BaseController
      end
    end
  end
end
```

`web/lib/generators/hunter/module/templates/api_resources_controller.rb.tt`:

```erb
module Api
  module V1
    module <%= module_namespace %>
      # <%= resource_plural.camelize %> API — full CRUD. No validation this pass.
      class <%= resource_plural.camelize %>Controller < BaseController
        def index
          filters = filter_params
          page = pagination_page
          limit = clamped_limit

          docs = ::<%= module_namespace %>::MongoSource.all(filters: filters, page: page, limit: limit)
          render json: {
            count: ::<%= module_namespace %>::MongoSource.count(filters: filters),
            page: page,
            limit: limit,
            <%= resource_plural %>: docs.map { |doc| serialize(doc) }
          }
        end

        def show
          doc = ::<%= module_namespace %>::MongoSource.find(params[:id])
          return render_not_found unless doc

          render json: serialize(doc)
        end

        def create
          id = ::<%= module_namespace %>::MongoSource.create(document_params)
          render json: { id: id }, status: :created
        end

        def update
          doc = ::<%= module_namespace %>::MongoSource.update(params[:id], document_params)
          return render_not_found unless doc

          render json: serialize(doc)
        end

        def destroy
          return head(:no_content) if ::<%= module_namespace %>::MongoSource.delete(params[:id])

          render_not_found
        end

        private

        def filter_params
          params.permit().to_h
        end

        def document_params
          params.except(:controller, :action, :format, :id, :<%= resource_singular %>).permit!.to_h
        end

        def serialize(doc)
          ::<%= resource_class %>.new(doc).as_json
        end
      end
    end
  end
end
```

`web/lib/generators/hunter/module/templates/web_base_controller.rb.tt`:

```erb
module <%= module_namespace %>
  # Web department base for the <%= module_slug %> section. Declares the tabs;
  # per-tab controllers subclass this.
  class BaseController < ApplicationController
    include Department

    TABS = [
      { label: "Overview", path: "/<%= module_slug %>" }
    ].freeze
  end
end
```

`web/lib/generators/hunter/module/templates/web_overview_controller.rb.tt`:

```erb
module <%= module_namespace %>
  class OverviewController < BaseController
    def index
    end
  end
end
```

`web/lib/generators/hunter/module/templates/view_index.html.erb.tt`:

```erb
<% content_for :title, "hunter — <%%= "<%= module_namespace %>" %>" %>
<%%= render "<%= module_slug %>/subnav" %>
<h1 class="text-2xl font-semibold text-zinc-900 dark:text-zinc-100"><%= module_namespace %></h1>
<p class="mt-2 text-zinc-500 dark:text-zinc-400">Coming soon.</p>
```

`web/lib/generators/hunter/module/templates/subnav.html.erb.tt`:

```erb
<nav class="mb-4 flex gap-4 border-b border-zinc-200 dark:border-white/10">
  <%% section_tabs.each do |tab| %>
    <%%= link_to tab[:label], tab[:path],
          class: "border-b-2 px-1 pb-2 text-sm #{section_tab_active?(tab[:path]) ? 'border-zinc-900 text-zinc-900 dark:border-zinc-100 dark:text-zinc-100' : 'border-transparent text-zinc-500 hover:text-zinc-700 dark:text-zinc-400'}",
          'aria-current': (section_tab_active?(tab[:path]) ? 'page' : nil) %>
  <%% end %>
</nav>
```

`web/lib/generators/hunter/module/templates/service_test.rb.tt`:

```erb
require "test_helper"

class <%= module_namespace %>::MongoSourceTest < ActiveSupport::TestCase
  Source = <%= module_namespace %>::MongoSource

  test "all returns [] when Mongo raises" do
    fake = Object.new
    def fake.find(*) = raise(Mongo::Error.new("down"))
    stub_methods(Source, collection: fake) do
      assert_equal [], Source.all
    end
  end
end
```

`web/lib/generators/hunter/module/templates/api_test.rb.tt`:

```erb
require "test_helper"

class Api::V1::<%= module_namespace %>::<%= resource_plural.camelize %>Test < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }

  Source = <%= module_namespace %>::MongoSource

  test "returns 401 without a cookie or token" do
    get "/api/v1/<%= module_slug %>/<%= resource_plural %>"
    assert_response :unauthorized
  end

  test "index works for a cookie-authenticated user" do
    sign_in_as(@user)
    stub_methods(Source, all: [{ "id" => "1" }], count: 1) do
      get "/api/v1/<%= module_slug %>/<%= resource_plural %>"
      assert_response :success
      assert_equal 1, JSON.parse(response.body)["count"]
    end
  end
end
```

`web/lib/generators/hunter/module/templates/model_test.rb.tt`:

```erb
require "test_helper"

class <%= resource_class %>Test < ActiveSupport::TestCase
  test "as_json stringifies keys" do
    assert_equal({ "a" => 1 }, <%= resource_class %>.new(a: 1).as_json)
  end
end
```

`web/lib/generators/hunter/module/USAGE`:

```
Description:
    Scaffolds an isolated Hunter module (service, model, namespaced API,
    tabbed web department, tests) and registers it in routes + sidebar nav.

Example:
    bin/rails generate hunter:module github --resource=repository
```

- [ ] **Step 5: Run the generator test, verify it passes**

Run: `cd web && bin/rails test test/lib/generators/hunter/module_generator_test.rb`
Expected: PASS (both tests).

- [ ] **Step 6: Add the three anchor comments to the real routes + nav files**

In `web/config/routes.rb`:
- Add `  # hunter:module-routes (web)` as the line immediately before the web department routes (above `get "programs", ...`).
- Add `      # hunter:module-routes (api)` as the first line inside `namespace :v1 do`.

In `web/app/helpers/navigation_helper.rb`, add `      # hunter:module-nav` as the first line inside the modules group (the second array in `primary_nav_groups`, immediately before the `Programs` entry).

These are inert comments; they only mark where the generator injects. Run `cd web && bin/rails test` to confirm nothing broke.

- [ ] **Step 7: Smoke-test the generator against the real app, then revert**

```bash
cd web && bin/rails g hunter:module widgets --resource=widget
bin/rails runner 'Rails.application.eager_load!' && bin/rails test test/integration/api/v1/widgets/widgets_test.rb test/services/widgets/mongo_source_test.rb test/models/widget_test.rb
```
Expected: zeitwerk loads cleanly; routes + nav gain `widgets` entries; the three generated tests PASS. Then revert the smoke module (anchors remain):
```bash
git checkout config/routes.rb app/helpers/navigation_helper.rb && rm -rf app/services/widgets app/models/widget.rb app/controllers/api/v1/widgets app/controllers/widgets app/views/widgets test/services/widgets test/integration/api/v1/widgets test/models/widget_test.rb
```
Note: `git checkout` here reverts only the generator's *injections* back to the committed-or-staged anchor state; re-add the anchors from Step 6 if they were not yet staged. Safer: stage Step 6 first (Step 8), then smoke-test, then `git checkout` returns to the staged anchors.

- [ ] **Step 8: Stage (do not commit)**

```bash
cd web && git add lib/generators/hunter/ test/lib/generators/ config/routes.rb app/helpers/navigation_helper.rb
```

---

### Task 4: Update AGENTS.md docs

**Files:**
- Modify: `AGENTS.md` ("How to add a module" section)

**Interfaces:**
- Consumes: the generator + anchors delivered in Task 3.
- Produces: accurate, generator-first module docs.

- [ ] **Step 1: Rewrite the AGENTS.md "How to add a module" section**

Replace the current numbered manual steps with the generator-first flow:

```markdown
## How to add a module (the pattern)

Run the generator — it produces the entire isolated module and registers it:

    bin/rails g hunter:module <module> --resource=<singular>

This creates, all module-owned (nothing else is touched but routes + nav):

- `app/services/<module>/mongo_source.rb` — `COLLECTION` + `INDEXES` + CRUD.
- `app/models/<resource>.rb` — flat PORO over a normalized Mongo doc.
- `app/controllers/api/v1/<module>/{base,<resources>}_controller.rb` —
  `Api::V1::<Module>::BaseController < Api::V1::BaseController` and the CRUD
  controller, served at `/api/v1/<module>/<resources>`.
- `app/controllers/<module>/{base,overview}_controller.rb` — the web
  "department"; `BaseController` includes `Department` and declares `TABS`,
  one controller per tab.
- `app/views/<module>/overview/index.html.erb` + `_subnav.html.erb` — the
  tabbed UI; `_subnav` renders from `TABS` via the `Department` concern.
- `test/{services,integration/api/v1,models}/...` — mirrored tests
  (service doubles Mongo; API stubs the service; model unit test).

Central registration is two one-liners the generator writes for you: a
`config/routes.rb` block (web + api) and a sidebar entry in
`app/helpers/navigation_helper.rb`.

Add more tabs by adding a controller + view under the module and an entry to
its `TABS`. The vulnerability-management module is the canonical reference.
```

- [ ] **Step 2: Run the full suite once more**

Run: `cd web && bin/rails test`
Expected: PASS (all).

- [ ] **Step 3: Stage (do not commit)**

```bash
cd /home/claude/workspace && git add AGENTS.md
```

---

## Notes for the executor

- **No commits.** When all four tasks are staged and green, stop and report. The user will say "go" to authorize a single commit covering the work.
- If Postgres `hunter_test` is unreachable, surface it as a blocker — don't skip tests.
- Keep the `Vulnerability` PORO and `Vulnerabilities::MongoSource` behavior unchanged; only their callers/paths move.
