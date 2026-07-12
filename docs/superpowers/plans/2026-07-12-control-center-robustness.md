# Control Center Robustness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add raw-YAML template authoring + file upload + live YAML validation, and a Statistics tab, to the Control Center — securely, consuming the existing API and services.

**Architecture:** Single source of truth stays the structured Template columns. Raw YAML and file upload are input surfaces parsed by a new safe `ControlCenter::TemplateYaml` service into those columns, where `TemplateValidator` still runs (allowlist unbypassable). A new `ControlCenter::JobStats` service aggregates the jobs table for a stats API and a server-rendered Statistics tab. No new gems; YAML is stdlib Psych; charts are inline SVG.

**Tech Stack:** Ruby 3.3.6, Rails 8.1, PostgreSQL, Hotwire (importmap + Stimulus), Tailwind, Minitest, stdlib `YAML`/Psych.

## Global Constraints

- Namespacing: services/models/web controllers under `ControlCenter::`; JSON API under `Api::V1::ControlCenter::`.
- YAML parsing MUST be `YAML.safe_load(str, permitted_classes: [], permitted_symbols: [], aliases: false)` — never `YAML.load`/`unsafe_load`. Size cap before parse: `MAX_YAML_BYTES = 64_000`.
- Parsed `commands` MUST flow through `ControlCenter::TemplateValidator` (command allowlist + arg metacharacters + caps) on every save; the binary only ever receives `TemplateRenderer`-produced YAML from validated structured fields — never raw user bytes.
- The cmdscript YAML schema (ground truth): mapping with keys `name`(string, required), `tags`(list of strings), `desc`/`description`(string), `output`(string), `commands`(list of `{command, args, operator}`, ≥1), `target`(optional `{type, separator, output}`). Workflow-kind YAML is out of scope.
- No new gems. Charts are inline SVG using `ChartsHelper` pure functions. Statistics tab is server-rendered (no JS controller).
- Rows/cells built from data in JS use `createElement`/`textContent` (never `innerHTML` with data). Non-GET fetches send `X-CSRF-Token` via the shared `apiFetch` (`lib/api_fetch`).
- Design language: monochrome zinc/black + dark mode (`dark:`); color only for functional status (emerald `#10b981` / rose `#f43f5e` / zinc `#a1a1aa`).
- Commit author `Claude <noreply@anthropic.com>`; commit messages a single sentence.
- Tests: `cd web && bin/rails test`. Postgres `hunter_test` is up; `Rails.cache` is `:null_store` in test (so `JobStats` recomputes every call). Use `sign_in_as(@user)` + `users(:one)`. A known pre-existing load failure in `test/integration/api/runner/jobs_test.rb` is unrelated — do not touch it; run focused test files per task.

---

### Task 1: `ControlCenter::TemplateYaml` service (YAML security core)

Safe parser: raw cmdscript YAML → normalized Template attributes, with schema validation. Does not run the command allowlist (that stays in `TemplateValidator`).

**Files:**
- Create: `web/app/services/control_center/template_yaml.rb`
- Test: `web/test/services/control_center/template_yaml_test.rb`

**Interfaces:**
- Produces: `ControlCenter::TemplateYaml.parse(str) -> [attrs_hash_or_nil, errors_array]`. On success `attrs` has string keys `name, kind, tags, description, output(optional), commands:[{command,args,operator}], target(optional {type,separator,output})`. Also `ControlCenter::TemplateYaml::MAX_YAML_BYTES`.

- [ ] **Step 1: Write the failing test**

```ruby
require "test_helper"

class ControlCenter::TemplateYamlTest < ActiveSupport::TestCase
  Y = ControlCenter::TemplateYaml

  test "parses a valid cmdscript template" do
    attrs, errors = Y.parse(<<~YAML)
      name: probe
      tags: [recon]
      desc: probe hosts
      output: probe.json
      commands:
        - command: httpx
          args: [-silent, -json]
          operator: "|"
        - command: nuclei
          args: [-severity, high]
      target:
        type: file
        separator: "\\n"
        output: targets.txt
    YAML
    assert_empty errors
    assert_equal "probe", attrs["name"]
    assert_equal "cmdscript", attrs["kind"]
    assert_equal ["recon"], attrs["tags"]
    assert_equal "probe hosts", attrs["description"]
    assert_equal "probe.json", attrs["output"]
    assert_equal 2, attrs["commands"].length
    assert_equal "httpx", attrs["commands"][0]["command"]
    assert_equal ["-silent", "-json"], attrs["commands"][0]["args"]
    assert_equal "|", attrs["commands"][0]["operator"]
    assert_equal "file", attrs["target"]["type"]
  end

  test "rejects a non-mapping root" do
    attrs, errors = Y.parse("- a\n- b")
    assert_nil attrs
    assert(errors.any? { |e| e.include?("must be a YAML mapping") })
  end

  test "rejects unknown top-level keys" do
    _attrs, errors = Y.parse("name: x\ncommands: []\nevil: 1")
    assert(errors.any? { |e| e.include?("unknown key") && e.include?("evil") })
  end

  test "rejects a Ruby object tag without instantiating it" do
    attrs, errors = Y.parse("--- !ruby/object:Kernel {}")
    assert_nil attrs
    refute_empty errors
  end

  test "rejects an alias/anchor bomb" do
    attrs, errors = Y.parse("a: &a [1,1]\nb: [*a, *a]\ncommands: *a\n")
    assert_nil attrs
    refute_empty errors
  end

  test "enforces the size cap" do
    attrs, errors = Y.parse("name: " + ("x" * 70_000))
    assert_nil attrs
    assert(errors.any? { |e| e.include?("too large") })
  end

  test "reports required and type errors" do
    attrs, errors = Y.parse("name: 5\ncommands: not-a-list")
    assert_nil attrs
    assert(errors.any? { |e| e.include?("name must be a string") })
    assert(errors.any? { |e| e.include?("commands must be a list") })
  end

  test "requires name" do
    attrs, errors = Y.parse("commands: []")
    assert_nil attrs
    assert(errors.any? { |e| e.include?("name is required") })
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bin/rails test test/services/control_center/template_yaml_test.rb`
Expected: FAIL — `uninitialized constant ControlCenter::TemplateYaml`.

- [ ] **Step 3: Write the implementation**

`web/app/services/control_center/template_yaml.rb`:

```ruby
require "yaml"

module ControlCenter
  # Safe parser: raw cmdscript YAML -> normalized Template attributes. The YAML
  # security core. Never YAML.load/unsafe_load — safe_load with no permitted
  # classes and aliases disabled blocks object-injection and alias/anchor bombs.
  # Returns [attrs_hash, []] on success or [nil, [error_strings]]. Does NOT run
  # the command allowlist — that stays in TemplateValidator, called by the model.
  module TemplateYaml
    module_function

    MAX_YAML_BYTES = 64_000
    ALLOWED_KEYS = %w[name kind tags desc description output commands target].freeze
    KINDS = %w[cmdscript workflow].freeze
    COMMAND_KEYS = %w[command args operator].freeze
    TARGET_KEYS = %w[type separator output].freeze

    def parse(str)
      str = str.to_s
      return [nil, ["YAML is empty"]] if str.strip.empty?
      return [nil, ["YAML is too large (max #{MAX_YAML_BYTES} bytes)"]] if str.bytesize > MAX_YAML_BYTES

      begin
        doc = YAML.safe_load(str, permitted_classes: [], permitted_symbols: [], aliases: false)
      rescue Psych::SyntaxError => e
        return [nil, ["YAML syntax error: #{e.message}"]]
      rescue StandardError => e
        return [nil, ["disallowed or invalid YAML: #{e.class}"]]
      end

      return [nil, ["template must be a YAML mapping"]] unless doc.is_a?(Hash)

      errors = []
      d = doc.transform_keys(&:to_s)
      unknown = d.keys - ALLOWED_KEYS
      errors << "unknown key(s): #{unknown.join(', ')}" if unknown.any?

      attrs = {
        "name" => required_string(d, "name", errors),
        "kind" => kind_field(d, errors),
        "tags" => string_list(d, "tags", errors),
        "description" => description_field(d, errors),
        "output" => optional_string(d, "output", errors),
        "commands" => commands_field(d, errors),
        "target" => target_field(d, errors)
      }
      attrs.reject! { |_k, v| v.nil? }

      return [nil, errors] if errors.any?
      [attrs, []]
    end

    def required_string(d, key, errors)
      unless d.key?(key)
        errors << "#{key} is required"
        return nil
      end
      return d[key] if d[key].is_a?(String)
      errors << "#{key} must be a string"
      nil
    end

    def optional_string(d, key, errors)
      return nil unless d.key?(key)
      return d[key] if d[key].is_a?(String)
      errors << "#{key} must be a string"
      nil
    end

    def kind_field(d, errors)
      return "cmdscript" unless d.key?("kind")
      v = d["kind"]
      return v if v.is_a?(String) && KINDS.include?(v)
      errors << "kind must be one of #{KINDS.join('/')}"
      "cmdscript"
    end

    def description_field(d, errors)
      key = d.key?("desc") ? "desc" : "description"
      return "" unless d.key?(key)
      return d[key] if d[key].is_a?(String)
      errors << "#{key} must be a string"
      ""
    end

    def string_list(d, key, errors)
      return [] unless d.key?(key)
      v = d[key]
      return v if v.is_a?(Array) && v.all? { |x| x.is_a?(String) }
      errors << "#{key} must be a list of strings"
      []
    end

    def commands_field(d, errors)
      v = d["commands"]
      unless v.is_a?(Array)
        errors << "commands must be a list"
        return []
      end
      v.each_with_index.map { |raw, i| command_entry(raw, i, errors) }
    end

    def command_entry(raw, i, errors)
      unless raw.is_a?(Hash)
        errors << "commands[#{i}] must be a mapping"
        return {}
      end
      c = raw.transform_keys(&:to_s)
      bad = c.keys - COMMAND_KEYS
      errors << "commands[#{i}] has unknown key(s): #{bad.join(', ')}" if bad.any?

      name = c["command"]
      unless name.is_a?(String)
        errors << "commands[#{i}].command must be a string"
        name = ""
      end
      args = c.fetch("args", [])
      unless args.is_a?(Array)
        errors << "commands[#{i}].args must be a list"
        args = []
      end
      operator = c.fetch("operator", "")
      unless operator.is_a?(String)
        errors << "commands[#{i}].operator must be a string"
        operator = ""
      end
      { "command" => name, "args" => args.map(&:to_s), "operator" => operator }
    end

    def target_field(d, errors)
      return nil unless d.key?("target")
      v = d["target"]
      unless v.is_a?(Hash)
        errors << "target must be a mapping"
        return nil
      end
      t = v.transform_keys(&:to_s)
      bad = t.keys - TARGET_KEYS
      errors << "target has unknown key(s): #{bad.join(', ')}" if bad.any?
      TARGET_KEYS.each do |k|
        errors << "target.#{k} must be a string" if t.key?(k) && !t[k].is_a?(String)
      end
      t.slice(*TARGET_KEYS)
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bin/rails test test/services/control_center/template_yaml_test.rb`
Expected: PASS (8 runs, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add web/app/services/control_center/template_yaml.rb web/test/services/control_center/template_yaml_test.rb
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Add ControlCenter::TemplateYaml safe cmdscript YAML parser and schema validator"
```

---

### Task 2: Templates API — YAML create/update, validate_yaml, serialize yaml

Let the templates API accept a `yaml` param, add a `validate_yaml` dry-run, and include rendered YAML in serialization.

**Files:**
- Modify: `web/app/controllers/api/v1/control_center/templates_controller.rb`
- Modify: `web/config/routes.rb` (add `post :validate_yaml` to the templates collection)
- Test: `web/test/integration/api/v1/control_center/templates_yaml_test.rb`

**Interfaces:**
- Consumes: `ControlCenter::TemplateYaml.parse` (Task 1), `ControlCenter::TemplateValidator.call`, `ControlCenter::TemplateRenderer.to_yaml`.
- Produces: route `validate_yaml_api_v1_control_center_templates_path`; `serialize` adds a `yaml` field; create/update accept a `yaml` param.

- [ ] **Step 1: Write the failing test**

```ruby
require "test_helper"

class Api::V1::ControlCenter::TemplatesYamlTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }

  test "validate_yaml reports valid for a good template" do
    sign_in_as(@user)
    post "/api/v1/control_center/templates/validate_yaml",
         params: { yaml: "name: probe\ncommands:\n  - command: httpx\n    args: [-silent]\n" }, as: :json
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal true, body["valid"]
    assert_empty body["errors"]
    assert_equal "probe", body["template"]["name"]
  end

  test "validate_yaml surfaces the command allowlist" do
    sign_in_as(@user)
    post "/api/v1/control_center/templates/validate_yaml",
         params: { yaml: "name: bad\ncommands:\n  - command: rm\n    args: [-rf]\n" }, as: :json
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal false, body["valid"]
    assert(body["errors"].any? { |e| e.include?("is not allowed") })
  end

  test "validate_yaml rejects malicious YAML without persisting" do
    sign_in_as(@user)
    post "/api/v1/control_center/templates/validate_yaml",
         params: { yaml: "--- !ruby/object:Kernel {}" }, as: :json
    assert_response :success
    assert_equal false, JSON.parse(response.body)["valid"]
    assert_equal 0, ControlCenter::Template.count
  end

  test "create via yaml persists a valid template" do
    sign_in_as(@user)
    post "/api/v1/control_center/templates",
         params: { yaml: "name: fromyaml\ncommands:\n  - command: httpx\n    args: [-silent]\n" }, as: :json
    assert_response :created
    assert ControlCenter::Template.exists?(name: "fromyaml")
  end

  test "create via yaml rejects a non-allowlisted command with 422" do
    sign_in_as(@user)
    post "/api/v1/control_center/templates",
         params: { yaml: "name: evil\ncommands:\n  - command: rm\n    args: [-rf]\n" }, as: :json
    assert_response :unprocessable_entity
    assert_not ControlCenter::Template.exists?(name: "evil")
  end

  test "serialize includes rendered yaml" do
    sign_in_as(@user)
    t = ControlCenter::Template.create!(name: "ser", commands: [{ "command" => "httpx", "args" => ["-silent"], "operator" => "" }])
    get "/api/v1/control_center/templates/#{t.id}"
    assert_response :success
    assert_includes JSON.parse(response.body)["yaml"], "httpx"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bin/rails test test/integration/api/v1/control_center/templates_yaml_test.rb`
Expected: FAIL — no `validate_yaml` route.

- [ ] **Step 3: Add the route**

In `web/config/routes.rb`, in the `namespace :control_center` block under `namespace :api { namespace :v1 }`, change the templates resource's collection block from:

```ruby
        resources :templates, only: %i[index show create update destroy] do
          collection { post :validate }
        end
```

to:

```ruby
        resources :templates, only: %i[index show create update destroy] do
          collection do
            post :validate
            post :validate_yaml
          end
        end
```

- [ ] **Step 4: Update the controller**

In `web/app/controllers/api/v1/control_center/templates_controller.rb`, replace the `create`, `update`, and `serialize` methods and add `validate_yaml` + a private `build_attrs`. The full file becomes:

```ruby
module Api
  module V1
    module ControlCenter
      # CRUD over ControlCenter::Template plus dry-run /validate (structured) and
      # /validate_yaml (raw YAML). A `yaml` param on create/update is parsed by
      # TemplateYaml into structured attrs; the model's TemplateValidator still
      # runs, so the command allowlist can't be bypassed via YAML.
      class TemplatesController < BaseController
        def index
          templates = ::ControlCenter::Template.order(:name)
          render json: { templates: templates.map { |t| serialize(t) } }
        end

        def show
          template = ::ControlCenter::Template.find_by(id: params[:id])
          return render_not_found unless template
          render json: serialize(template)
        end

        def create
          attrs, yaml_errors = build_attrs
          return render_yaml_errors(yaml_errors) if yaml_errors.any?
          template = ::ControlCenter::Template.new(attrs.merge("created_by" => Current.user&.username))
          return render_unprocessable(template) unless template.save
          render json: serialize(template), status: :created
        end

        def update
          template = ::ControlCenter::Template.find_by(id: params[:id])
          return render_not_found unless template
          attrs, yaml_errors = build_attrs
          return render_yaml_errors(yaml_errors) if yaml_errors.any?
          return render_unprocessable(template) unless template.update(attrs)
          render json: serialize(template)
        end

        def destroy
          template = ::ControlCenter::Template.find_by(id: params[:id])
          return render_not_found unless template
          template.destroy
          head :no_content
        end

        def validate
          errors = ::ControlCenter::TemplateValidator.call(commands_param)
          render json: { valid: errors.empty?, errors: errors }
        end

        def validate_yaml
          attrs, errors = ::ControlCenter::TemplateYaml.parse(params[:yaml])
          errors = errors.dup
          errors.concat(::ControlCenter::TemplateValidator.call(attrs["commands"])) if attrs
          render json: { valid: errors.empty?, errors: errors, template: attrs }
        end

        private

        # [attrs, errors] — from raw YAML when a `yaml` param is present, else from
        # the structured params. YAML parse errors short-circuit before the model.
        def build_attrs
          if params[:yaml].present?
            attrs, errors = ::ControlCenter::TemplateYaml.parse(params[:yaml])
            [attrs || {}, errors]
          else
            [template_params.to_h, []]
          end
        end

        def template_params
          params.permit(:name, :kind, :description, :output,
                        tags: [],
                        commands: [:command, :operator, { args: [] }],
                        target: [:type, :separator, :output]).to_h
        end

        def commands_param
          params.permit(commands: [:command, :operator, { args: [] }]).to_h["commands"]
        end

        def serialize(t)
          {
            id: t.id, name: t.name, kind: t.kind, tags: t.tags,
            description: t.description, output: t.output, commands: t.commands,
            target: t.target, created_by: t.created_by,
            yaml: ::ControlCenter::TemplateRenderer.to_yaml(t),
            created_at: t.created_at, updated_at: t.updated_at
          }
        end

        def render_unprocessable(record)
          render json: { error: "unprocessable_entity", detail: record.errors.full_messages }, status: :unprocessable_entity
        end

        def render_yaml_errors(errors)
          render json: { error: "unprocessable_entity", detail: errors }, status: :unprocessable_entity
        end
      end
    end
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd web && bin/rails test test/integration/api/v1/control_center/templates_yaml_test.rb`
Expected: PASS (6 runs, 0 failures).

- [ ] **Step 6: Run the existing templates test to confirm no regression**

Run: `cd web && bin/rails test test/integration/api/v1/control_center/templates_test.rb`
Expected: PASS (4 runs, 0 failures — the added `yaml` serialize field doesn't break existing assertions).

- [ ] **Step 7: Commit**

```bash
git add web/config/routes.rb web/app/controllers/api/v1/control_center/templates_controller.rb web/test/integration/api/v1/control_center/templates_yaml_test.rb
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Add YAML create/update, validate_yaml, and rendered-yaml serialization to templates API"
```

---

### Task 3: Templates tab UI — YAML mode, file upload, debounced validation

Add a Structured/YAML mode toggle, a YAML textarea prefilled on edit, a client-side file loader, live `validate_yaml`, and debounce both validators.

**Files:**
- Modify: `web/app/views/control_center/templates/index.html.erb`
- Modify: `web/app/javascript/controllers/control_center_templates_controller.js`
- Test: `web/test/integration/control_center/tabs_test.rb` (extend)

**Interfaces:**
- Consumes: `validate_yaml_api_v1_control_center_templates_path` (Task 2); `apiFetch`.
- Produces: Stimulus value `validateYamlUrl`; targets `modeStructured/modeYaml/structuredPanel/yamlPanel/yamlText/yamlErrors/yamlValid/fileInput`.

- [ ] **Step 1: Write the failing test (extend tabs_test.rb)**

Add inside `class ControlCenter::TabsTest`:

```ruby
  test "templates page wires the YAML editor and file upload" do
    sign_in_as(@user)
    get control_center_root_path
    assert_select "section[data-controller~=control-center-templates]" \
                  "[data-control-center-templates-validate-yaml-url-value=?]",
                  validate_yaml_api_v1_control_center_templates_path
    assert_select "textarea[data-control-center-templates-target=yamlText]"
    assert_select "input[type=file][data-control-center-templates-target=fileInput]"
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bin/rails test test/integration/control_center/tabs_test.rb`
Expected: FAIL — missing `validate-yaml-url-value` / `yamlText` / `fileInput`.

- [ ] **Step 3: Update the shell view**

In `web/app/views/control_center/templates/index.html.erb`:

(a) Add the `validateYaml` value to the section's opening tag — change:

```erb
         data-control-center-templates-jobs-url-value="<%= api_v1_control_center_jobs_path %>">
```

to:

```erb
         data-control-center-templates-jobs-url-value="<%= api_v1_control_center_jobs_path %>"
         data-control-center-templates-validate-yaml-url-value="<%= validate_yaml_api_v1_control_center_templates_path %>">
```

(b) Inside the editor panel (`data-control-center-templates-target="editor"`), immediately after the opening `<div ...editor...>` tag and before the structured fields grid, insert the mode toggle + file input:

```erb
    <div class="mb-3 flex items-center gap-2">
      <div class="inline-flex overflow-hidden rounded-md border border-zinc-300 dark:border-zinc-700">
        <button type="button" data-control-center-templates-target="modeStructured" data-action="control-center-templates#showStructured"
                class="px-3 py-1 text-sm font-medium bg-zinc-900 text-white dark:bg-white dark:text-zinc-900">Structured</button>
        <button type="button" data-control-center-templates-target="modeYaml" data-action="control-center-templates#showYaml"
                class="px-3 py-1 text-sm font-medium text-zinc-700 hover:bg-zinc-100 dark:text-zinc-200 dark:hover:bg-zinc-800">YAML</button>
      </div>
      <label class="ml-auto inline-flex cursor-pointer items-center gap-1.5 rounded-md border border-zinc-300 px-2.5 py-1 text-sm font-medium text-zinc-700 hover:bg-zinc-100 dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800">
        Upload .yaml
        <input type="file" accept=".yaml,.yml,text/yaml" class="hidden"
               data-control-center-templates-target="fileInput" data-action="control-center-templates#onFile">
      </label>
    </div>
```

(c) Wrap the existing structured fields grid (the `<div class="grid gap-3 sm:grid-cols-2">…</div>`) and the Commands block and the existing `errors` list in a structured panel by adding a wrapper `<div data-control-center-templates-target="structuredPanel">` immediately before the `<div class="grid gap-3 sm:grid-cols-2">` and its matching `</div>` immediately after the existing errors `<ul ...errors...></ul>`. Then add the YAML panel right after that wrapper:

```erb
    <div data-control-center-templates-target="yamlPanel" class="hidden">
      <textarea data-control-center-templates-target="yamlText" data-action="input->control-center-templates#validateYaml"
                rows="16" spellcheck="false"
                class="w-full rounded-md border border-zinc-300 bg-white px-2 py-1.5 font-mono text-sm dark:border-zinc-700 dark:bg-zinc-900"
                placeholder="name: probe&#10;commands:&#10;  - command: httpx&#10;    args: [-silent]"></textarea>
      <div class="mt-2 flex items-center gap-2">
        <span data-control-center-templates-target="yamlValid" class="hidden rounded bg-emerald-100 px-1.5 py-0.5 text-xs font-medium text-emerald-800 dark:bg-emerald-950/50 dark:text-emerald-300">valid</span>
      </div>
      <ul data-control-center-templates-target="yamlErrors" class="mt-2 hidden list-disc space-y-1 rounded-md bg-rose-50 px-5 py-2 text-xs text-rose-700 dark:bg-rose-950/40 dark:text-rose-300"></ul>
    </div>
```

(d) Change the structured inputs' live-validation action from `#validate` to `#validateDebounced` (the `fName` input and each command-row field). In the `fName` input change `data-action="input->control-center-templates#validate"` to `data-action="input->control-center-templates#validateDebounced"`; in the `<template data-control-center-templates-target="commandRow">` row change the two `input->control-center-templates#validate` and the `change->control-center-templates#validate` to `#validateDebounced`.

- [ ] **Step 4: Update the Stimulus controller**

In `web/app/javascript/controllers/control_center_templates_controller.js`, make these changes:

(a) Replace the `static values` and `static targets` declarations with:

```javascript
  static values = { indexUrl: String, validateUrl: String, jobsUrl: String, validateYamlUrl: String }
  static targets = [
    "rows", "empty", "editor", "commands", "commandRow", "errors", "save",
    "fName", "fKind", "fOutput", "fTags", "fDescription",
    "sendDialog", "sendName", "sendTargets", "sendQueue", "sendChunk", "sendDelay", "sendResult",
    "modeStructured", "modeYaml", "structuredPanel", "yamlPanel", "yamlText", "yamlErrors", "yamlValid", "fileInput",
  ]
```

(b) Replace `connect()` with one that also tracks mode and clears timers on disconnect:

```javascript
  connect() {
    this.editingId = null
    this.sendTemplate = null
    this.mode = "structured"
    this.refresh()
  }

  disconnect() {
    clearTimeout(this._valTimer)
    clearTimeout(this._yamlTimer)
  }
```

(c) In `newTemplate()` and `openEditor(t)`, after they call `this.editorTarget.classList.remove("hidden")`, add a reset to structured mode. Concretely, add `this.showStructured()` as the last line of both `newTemplate()` and `openEditor(t)` (after the existing body, before the method closes). Additionally, in `openEditor(t)`, prefill the YAML textarea by adding `this.yamlTextTarget.value = t.yaml || ""` just before that `this.showStructured()` line; in `newTemplate()` add `this.yamlTextTarget.value = ""` before it.

(d) Add these methods (place them after `closeEditor()`):

```javascript
  // --- editor mode + yaml ---------------------------------------------------

  showStructured() {
    this.mode = "structured"
    this.structuredPanelTarget.classList.remove("hidden")
    this.yamlPanelTarget.classList.add("hidden")
    this._activate(this.modeStructuredTarget, this.modeYamlTarget)
    this.validate()
  }

  showYaml() {
    this.mode = "yaml"
    this.yamlPanelTarget.classList.remove("hidden")
    this.structuredPanelTarget.classList.add("hidden")
    this._activate(this.modeYamlTarget, this.modeStructuredTarget)
    this.validateYaml()
  }

  _activate(on, off) {
    on.classList.add("bg-zinc-900", "text-white", "dark:bg-white", "dark:text-zinc-900")
    off.classList.remove("bg-zinc-900", "text-white", "dark:bg-white", "dark:text-zinc-900")
  }

  onFile(event) {
    const file = event.target.files && event.target.files[0]
    if (!file) return
    if (file.size > 64000) { window.alert("File is too large (max 64 KB)."); event.target.value = ""; return }
    const reader = new FileReader()
    reader.onload = () => {
      this.yamlTextTarget.value = String(reader.result || "")
      this.showYaml()
    }
    reader.readAsText(file)
    event.target.value = ""
  }

  validateDebounced() { clearTimeout(this._valTimer); this._valTimer = setTimeout(() => this.validate(), 300) }
  validateYaml() { clearTimeout(this._yamlTimer); this._yamlTimer = setTimeout(() => this._doValidateYaml(), 300) }

  async _doValidateYaml() {
    const { ok, data } = await apiFetch(this.validateYamlUrlValue, { method: "POST", body: { yaml: this.yamlTextTarget.value } })
    const valid = ok && data && data.valid
    const errors = ok && data ? data.errors : ["validation request failed"]
    this.yamlValidTarget.classList.toggle("hidden", !valid)
    this._renderYamlErrors(valid ? [] : errors)
    this.saveTarget.disabled = !valid
  }

  _renderYamlErrors(errors) {
    this.yamlErrorsTarget.replaceChildren()
    this.yamlErrorsTarget.classList.toggle("hidden", errors.length === 0)
    errors.forEach((msg) => {
      const li = document.createElement("li")
      li.textContent = msg
      this.yamlErrorsTarget.appendChild(li)
    })
  }
```

(e) Replace `save()` with a version that branches on mode:

```javascript
  async save() {
    let body
    if (this.mode === "yaml") {
      body = { yaml: this.yamlTextTarget.value }
    } else {
      body = {
        name: this.fNameTarget.value.trim(),
        kind: this.fKindTarget.value,
        output: this.fOutputTarget.value.trim(),
        description: this.fDescriptionTarget.value,
        tags: this.fTagsTarget.value.split(",").map((s) => s.trim()).filter(Boolean),
        commands: this.collectCommands(),
      }
    }
    const url = this.editingId ? `${this.indexUrlValue}/${this.editingId}` : this.indexUrlValue
    const method = this.editingId ? "PATCH" : "POST"
    const { ok, data } = await apiFetch(url, { method, body })
    if (ok) {
      this.closeEditor()
      this.refresh()
    } else if (this.mode === "yaml") {
      this._renderYamlErrors((data && data.detail) || ["save failed"])
    } else {
      this.showErrors((data && data.detail) || ["save failed"])
    }
  }
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd web && bin/rails test test/integration/control_center/tabs_test.rb`
Expected: PASS (8 runs, 0 failures — the 7 prior + the new one).

- [ ] **Step 6: Commit**

```bash
git add web/app/views/control_center/templates/index.html.erb web/app/javascript/controllers/control_center_templates_controller.js web/test/integration/control_center/tabs_test.rb
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Add YAML mode, file upload, and debounced validation to the Control Center templates tab"
```

---

### Task 4: `ControlCenter::JobStats` service + stats indexes

Aggregate the jobs table into one dashboard hash, with supporting indexes.

**Files:**
- Create: `web/db/migrate/20260712000001_add_control_center_jobs_stats_indexes.rb`
- Create: `web/app/services/control_center/job_stats.rb`
- Test: `web/test/services/control_center/job_stats_test.rb`

**Interfaces:**
- Produces: `ControlCenter::JobStats.dashboard -> { totals: {jobs,succeeded,failed,pending,success_rate,targets,templates_used}, by_status: [{label,count,color}], top_templates: [{label,count}], by_queue: [{label,count}], daily: [{date,count}] }`. Also `ControlCenter::JobStats::STATUS_COLORS`.

- [ ] **Step 1: Write the failing test**

```ruby
require "test_helper"

class ControlCenter::JobStatsTest < ActiveSupport::TestCase
  def job(**over)
    ControlCenter::Job.create!({ template_name: "t", status: "succeeded", queue_name: "test", target_count: 1 }.merge(over))
  end

  test "totals, success rate, targets, and distinct templates" do
    job(template_name: "a", status: "succeeded", target_count: 2)
    job(template_name: "a", status: "failed", target_count: 3)
    job(template_name: "b", status: "pending", target_count: 5)
    t = ControlCenter::JobStats.dashboard[:totals]
    assert_equal 3, t[:jobs]
    assert_equal 1, t[:succeeded]
    assert_equal 1, t[:failed]
    assert_equal 1, t[:pending]
    assert_equal 50, t[:success_rate]
    assert_equal 10, t[:targets]
    assert_equal 2, t[:templates_used]
  end

  test "top templates ranked by count" do
    3.times { job(template_name: "hot") }
    job(template_name: "cold")
    top = ControlCenter::JobStats.dashboard[:top_templates]
    assert_equal({ label: "hot", count: 3 }, top.first)
  end

  test "daily series is zero-filled to 30 days ending today" do
    job
    daily = ControlCenter::JobStats.dashboard[:daily]
    assert_equal 30, daily.length
    assert_equal 1, daily.sum { |d| d[:count] }
    assert_equal Date.current.iso8601, daily.last[:date]
  end

  test "by_status always lists the three statuses in order" do
    assert_equal %w[succeeded failed pending],
                 ControlCenter::JobStats.dashboard[:by_status].map { |r| r[:label] }
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bin/rails test test/services/control_center/job_stats_test.rb`
Expected: FAIL — `uninitialized constant ControlCenter::JobStats`.

- [ ] **Step 3: Write the migration and service**

`web/db/migrate/20260712000001_add_control_center_jobs_stats_indexes.rb`:

```ruby
class AddControlCenterJobsStatsIndexes < ActiveRecord::Migration[8.1]
  def change
    add_index :control_center_jobs, :template_name
    add_index :control_center_jobs, :status
  end
end
```

`web/app/services/control_center/job_stats.rb`:

```ruby
module ControlCenter
  # Read-only analytics over ControlCenter::Job (Postgres): one dashboard hash of
  # totals + breakdowns for the Statistics tab and the stats API. Parametrized AR
  # aggregates only; briefly cached; degrades to zeros/empties on error so the
  # tab never 500s.
  module JobStats
    module_function

    TOP_LIMIT = 8
    DAILY_DAYS = 30
    CACHE_KEY = "control_center:job_stats:dashboard".freeze
    CACHE_TTL = 60

    STATUS_COLORS = {
      "succeeded" => "#10b981",
      "failed" => "#f43f5e",
      "pending" => "#a1a1aa"
    }.freeze

    def dashboard
      Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_TTL) { compute }
    rescue StandardError
      empty
    end

    def compute
      counts = Job.group(:status).count
      succeeded = counts["succeeded"].to_i
      failed = counts["failed"].to_i
      pending = counts["pending"].to_i
      finished = succeeded + failed

      {
        totals: {
          jobs: counts.values.sum,
          succeeded: succeeded,
          failed: failed,
          pending: pending,
          success_rate: finished.zero? ? 0 : (succeeded * 100.0 / finished).round,
          targets: Job.sum(:target_count).to_i,
          templates_used: Job.distinct.count(:template_name)
        },
        by_status: STATUS_COLORS.map { |s, c| { label: s, count: counts[s].to_i, color: c } },
        top_templates: rank(Job.group(:template_name).count).first(TOP_LIMIT),
        by_queue: rank(Job.group(:queue_name).count),
        daily: daily_series
      }
    end

    # {key => count} -> [{label:, count:}] sorted by count desc.
    def rank(grouped)
      grouped.sort_by { |_k, n| -n }.map { |k, n| { label: k, count: n } }
    end

    def daily_series
      since = Date.current - (DAILY_DAYS - 1)
      rows = Job.where("created_at >= ?", since.beginning_of_day).group("created_at::date").count
      by_date = rows.transform_keys { |k| k.is_a?(Date) ? k : Date.parse(k.to_s) }
      (0...DAILY_DAYS).map do |i|
        d = since + i
        { date: d.iso8601, count: by_date[d].to_i }
      end
    end

    def empty
      {
        totals: { jobs: 0, succeeded: 0, failed: 0, pending: 0, success_rate: 0, targets: 0, templates_used: 0 },
        by_status: STATUS_COLORS.map { |s, c| { label: s, count: 0, color: c } },
        top_templates: [], by_queue: [], daily: []
      }
    end
  end
end
```

- [ ] **Step 4: Migrate and run the test**

Run: `cd web && bin/rails db:migrate && bin/rails test test/services/control_center/job_stats_test.rb`
Expected: migration applies (schema.rb updated); PASS (4 runs, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add web/db/migrate/20260712000001_add_control_center_jobs_stats_indexes.rb web/app/services/control_center/job_stats.rb web/test/services/control_center/job_stats_test.rb web/db/schema.rb
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Add ControlCenter::JobStats aggregate service and jobs stats indexes"
```

---

### Task 5: `ChartsHelper` geometry helpers

Pure functions for bar-list widths and daily-bar heights.

**Files:**
- Modify: `web/app/helpers/charts_helper.rb`
- Test: `web/test/helpers/charts_helper_test.rb` (append)

**Interfaces:**
- Produces: `bar_list_rows([{label,count}]) -> [{label,count,percent}]`; `daily_bars([{date,count}]) -> [{date,count,height_pct}]`. Percentages are scaled to the max count (0 when all zero).

- [ ] **Step 1: Write the failing test (append to charts_helper_test.rb)**

Add these tests to the existing `class ChartsHelperTest`:

```ruby
  test "bar_list_rows scales width to the max count" do
    rows = bar_list_rows([{ label: "a", count: 4 }, { label: "b", count: 1 }])
    assert_equal 100.0, rows[0][:percent]
    assert_equal 25.0, rows[1][:percent]
  end

  test "bar_list_rows handles all-zero without dividing by zero" do
    assert_equal 0, bar_list_rows([{ label: "a", count: 0 }])[0][:percent]
  end

  test "daily_bars scales height to the max count" do
    bars = daily_bars([{ date: "2026-07-01", count: 2 }, { date: "2026-07-02", count: 4 }])
    assert_equal 50.0, bars[0][:height_pct]
    assert_equal 100.0, bars[1][:height_pct]
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bin/rails test test/helpers/charts_helper_test.rb`
Expected: FAIL — `undefined method 'bar_list_rows'`.

- [ ] **Step 3: Add the helpers**

In `web/app/helpers/charts_helper.rb`, add these two public methods immediately BEFORE the `private` keyword (they use the existing private `round3`):

```ruby
  # [{label:, count:}] -> rows with a width percentage relative to the largest
  # count, so a horizontal bar list renders without per-view math.
  def bar_list_rows(data)
    rows = Array(data)
    max = rows.map { |r| r[:count].to_i }.max.to_i
    rows.map do |r|
      { label: r[:label], count: r[:count].to_i,
        percent: max.zero? ? 0 : round3(r[:count].to_i * 100.0 / max) }
    end
  end

  # [{date:, count:}] -> bars scaled to a fixed height for the daily chart.
  def daily_bars(series)
    rows = Array(series)
    max = rows.map { |r| r[:count].to_i }.max.to_i
    rows.map do |r|
      { date: r[:date], count: r[:count].to_i,
        height_pct: max.zero? ? 0 : round3(r[:count].to_i * 100.0 / max) }
    end
  end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd web && bin/rails test test/helpers/charts_helper_test.rb`
Expected: PASS (existing tests + 3 new, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add web/app/helpers/charts_helper.rb web/test/helpers/charts_helper_test.rb
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Add bar-list and daily-bar geometry helpers to ChartsHelper"
```

---

### Task 6: Stats API — `Api::V1::ControlCenter::StatsController`

Expose the dashboard as JSON for module API parity.

**Files:**
- Create: `web/app/controllers/api/v1/control_center/stats_controller.rb`
- Modify: `web/config/routes.rb` (add `resource :stats`)
- Test: `web/test/integration/api/v1/control_center/stats_test.rb`

**Interfaces:**
- Consumes: `ControlCenter::JobStats.dashboard` (Task 4).
- Produces: route `api_v1_control_center_stats_path` → `GET /api/v1/control_center/stats`.

- [ ] **Step 1: Write the failing test**

```ruby
require "test_helper"

class Api::V1::ControlCenter::StatsTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }

  test "requires auth" do
    get "/api/v1/control_center/stats"
    assert_response :unauthorized
  end

  test "returns the dashboard shape" do
    sign_in_as(@user)
    ControlCenter::Job.create!(template_name: "a", status: "succeeded", queue_name: "test", target_count: 2)
    get "/api/v1/control_center/stats"
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 1, body["totals"]["jobs"]
    assert body.key?("by_status")
    assert body.key?("top_templates")
    assert body.key?("daily")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bin/rails test test/integration/api/v1/control_center/stats_test.rb`
Expected: FAIL — no `stats` route.

- [ ] **Step 3: Add the route**

In `web/config/routes.rb`, inside the `namespace :control_center` block under `namespace :api { namespace :v1 }`, add alongside the existing `resource :health` line:

```ruby
        resource :stats, only: :show, controller: "stats"
```

- [ ] **Step 4: Write the controller**

`web/app/controllers/api/v1/control_center/stats_controller.rb`:

```ruby
module Api
  module V1
    module ControlCenter
      # Job analytics for external clients — the same data the Statistics tab
      # renders. JobStats degrades to zeros on error, so this never guards.
      class StatsController < BaseController
        def show
          render json: ::ControlCenter::JobStats.dashboard
        end
      end
    end
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd web && bin/rails test test/integration/api/v1/control_center/stats_test.rb`
Expected: PASS (2 runs, 0 failures).

- [ ] **Step 6: Commit**

```bash
git add web/config/routes.rb web/app/controllers/api/v1/control_center/stats_controller.rb web/test/integration/api/v1/control_center/stats_test.rb
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Add Control Center stats API endpoint"
```

---

### Task 7: Statistics web tab (server-rendered)

Add the Statistics tab: controller, TAB entry, route, and server-rendered SVG/bar views.

**Files:**
- Modify: `web/app/controllers/control_center/base_controller.rb` (add TAB)
- Modify: `web/config/routes.rb` (web `statistics` route)
- Create: `web/app/controllers/control_center/statistics_controller.rb`
- Create: `web/app/views/control_center/statistics/index.html.erb`
- Create: `web/app/views/control_center/statistics/_tile.html.erb`
- Create: `web/app/views/control_center/statistics/_bar_list.html.erb`
- Test: `web/test/integration/control_center/tabs_test.rb` (extend)

**Interfaces:**
- Consumes: `ControlCenter::JobStats.dashboard` (Task 4); `ChartsHelper` `donut_segments`/`bar_list_rows`/`daily_bars` (Task 5); the `control_center/_health` partial.
- Produces: route `control_center_statistics_path`; a third department tab.

- [ ] **Step 1: Write the failing test (extend tabs_test.rb)**

Add inside `class ControlCenter::TabsTest`:

```ruby
  test "statistics tab requires auth" do
    get control_center_statistics_path
    assert_redirected_to new_session_path
  end

  test "statistics tab renders tiles and the Statistics tab active" do
    sign_in_as(@user)
    ControlCenter::Job.create!(template_name: "a", status: "succeeded", queue_name: "test", target_count: 2)
    get control_center_statistics_path
    assert_response :success
    assert_select "a[href=?][aria-current=page]", control_center_statistics_path, text: "Statistics"
    assert_match "Jobs sent", response.body
    assert_select "svg"
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bin/rails test test/integration/control_center/tabs_test.rb`
Expected: FAIL — `control_center_statistics_path` undefined.

- [ ] **Step 3: Add the TAB, route, and controller**

In `web/app/controllers/control_center/base_controller.rb`, change `TABS` to:

```ruby
    TABS = [
      { name: "Templates",  path: :control_center_root_path },
      { name: "Jobs",       path: :control_center_jobs_path },
      { name: "Statistics", path: :control_center_statistics_path }
    ].freeze
```

In `web/config/routes.rb`, in the web `namespace :control_center` block, add after the `/jobs` line:

```ruby
    get "/statistics", to: "statistics#index", as: :statistics
```

`web/app/controllers/control_center/statistics_controller.rb`:

```ruby
module ControlCenter
  # Statistics tab: server-rendered job analytics. A thin pass-through — all
  # aggregation lives in JobStats, which degrades to safe zeros, so this action
  # never needs to guard.
  class StatisticsController < BaseController
    def index
      @stats = JobStats.dashboard
    end
  end
end
```

- [ ] **Step 4: Write the partials**

`web/app/views/control_center/statistics/_tile.html.erb`:

```erb
<div class="rounded-lg border border-zinc-200 bg-white p-3 dark:border-zinc-800 dark:bg-[#111315]">
  <div class="text-xs text-zinc-500 dark:text-zinc-400"><%= label %></div>
  <div class="mt-1 text-2xl font-semibold text-zinc-900 dark:text-zinc-100"><%= value %></div>
</div>
```

`web/app/views/control_center/statistics/_bar_list.html.erb`:

```erb
<% if rows.empty? %>
  <p class="py-8 text-center text-sm text-zinc-400 dark:text-zinc-500"><%= empty %></p>
<% else %>
  <ul class="space-y-2">
    <% rows.each do |r| %>
      <li>
        <div class="mb-0.5 flex items-center justify-between text-sm">
          <span class="truncate text-zinc-700 dark:text-zinc-200"><%= r[:label] %></span>
          <span class="ml-2 font-medium text-zinc-900 dark:text-zinc-100"><%= r[:count] %></span>
        </div>
        <div class="h-2 overflow-hidden rounded bg-zinc-100 dark:bg-zinc-800">
          <div class="h-full rounded bg-zinc-800 dark:bg-zinc-300" style="width: <%= r[:percent] %>%"></div>
        </div>
      </li>
    <% end %>
  </ul>
<% end %>
```

- [ ] **Step 5: Write the index view**

`web/app/views/control_center/statistics/index.html.erb`:

```erb
<% content_for :title, "hunter — Control Center statistics" %>
<% content_for :container, "mx-auto max-w-screen-2xl px-6 py-10" %>

<header class="flex items-center gap-3">
  <h1 class="text-2xl font-semibold text-zinc-900 dark:text-zinc-100">Control Center</h1>
  <span class="rounded border border-zinc-300 px-1.5 py-0.5 text-xs font-medium text-zinc-600 dark:border-zinc-700 dark:text-zinc-400">beta</span>
  <div class="ml-auto"><%= render "control_center/health" %></div>
</header>
<p class="mt-1 text-sm text-zinc-500 dark:text-zinc-400">Job analytics across every submission.</p>

<%= render "layouts/department_tabs", label: "Control Center sections" %>

<% t = @stats[:totals] %>
<section class="mt-6 grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-6">
  <%= render "control_center/statistics/tile", label: "Jobs sent", value: t[:jobs] %>
  <%= render "control_center/statistics/tile", label: "Succeeded", value: t[:succeeded] %>
  <%= render "control_center/statistics/tile", label: "Failed", value: t[:failed] %>
  <%= render "control_center/statistics/tile", label: "Success rate", value: "#{t[:success_rate]}%" %>
  <%= render "control_center/statistics/tile", label: "Targets sent", value: t[:targets] %>
  <%= render "control_center/statistics/tile", label: "Templates used", value: t[:templates_used] %>
</section>

<div class="mt-4 grid gap-4 lg:grid-cols-2">
  <section class="rounded-lg border border-zinc-200 bg-white p-4 dark:border-zinc-800 dark:bg-[#111315]">
    <h2 class="mb-3 text-sm font-medium text-zinc-700 dark:text-zinc-200">Jobs by status</h2>
    <% segments = donut_segments(@stats[:by_status]) %>
    <% if segments.empty? %>
      <p class="py-10 text-center text-sm text-zinc-400 dark:text-zinc-500">No jobs yet.</p>
    <% else %>
      <div class="flex items-center gap-6">
        <svg viewBox="0 0 36 36" class="h-32 w-32 -rotate-90" aria-hidden="true">
          <% segments.each do |s| %>
            <circle cx="18" cy="18" r="15.915" fill="none" stroke="<%= s[:color] %>" stroke-width="3.5"
                    stroke-dasharray="<%= s[:dasharray] %>" stroke-dashoffset="<%= s[:dashoffset] %>"></circle>
          <% end %>
        </svg>
        <ul class="space-y-1 text-sm">
          <% @stats[:by_status].each do |r| %>
            <li class="flex items-center gap-2 text-zinc-600 dark:text-zinc-300">
              <span class="h-2.5 w-2.5 rounded-full" style="background: <%= r[:color] %>"></span>
              <span class="capitalize"><%= r[:label] %></span>
              <span class="ml-6 font-medium text-zinc-900 dark:text-zinc-100"><%= r[:count] %></span>
            </li>
          <% end %>
        </ul>
      </div>
    <% end %>
  </section>

  <section class="rounded-lg border border-zinc-200 bg-white p-4 dark:border-zinc-800 dark:bg-[#111315]">
    <h2 class="mb-3 text-sm font-medium text-zinc-700 dark:text-zinc-200">Most-used templates</h2>
    <%= render "control_center/statistics/bar_list", rows: bar_list_rows(@stats[:top_templates]), empty: "No templates submitted yet." %>
  </section>
</div>

<div class="mt-4 grid gap-4 lg:grid-cols-2">
  <section class="rounded-lg border border-zinc-200 bg-white p-4 dark:border-zinc-800 dark:bg-[#111315]">
    <h2 class="mb-3 text-sm font-medium text-zinc-700 dark:text-zinc-200">Jobs by queue</h2>
    <%= render "control_center/statistics/bar_list", rows: bar_list_rows(@stats[:by_queue]), empty: "No jobs yet." %>
  </section>

  <section class="rounded-lg border border-zinc-200 bg-white p-4 dark:border-zinc-800 dark:bg-[#111315]">
    <h2 class="mb-3 text-sm font-medium text-zinc-700 dark:text-zinc-200">Jobs per day (30d)</h2>
    <% bars = daily_bars(@stats[:daily]) %>
    <% if bars.sum { |b| b[:count] }.zero? %>
      <p class="py-10 text-center text-sm text-zinc-400 dark:text-zinc-500">No jobs in the last 30 days.</p>
    <% else %>
      <div class="flex h-28 items-end gap-0.5">
        <% bars.each do |b| %>
          <div class="flex-1 rounded-t bg-zinc-800 dark:bg-zinc-300" style="height: <%= [b[:height_pct], 2].max %>%"
               title="<%= b[:date] %>: <%= b[:count] %>"></div>
        <% end %>
      </div>
      <div class="mt-1 flex justify-between text-[10px] text-zinc-400 dark:text-zinc-500">
        <span><%= bars.first[:date] %></span><span><%= bars.last[:date] %></span>
      </div>
    <% end %>
  </section>
</div>
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `cd web && bin/rails test test/integration/control_center/tabs_test.rb`
Expected: PASS (10 runs, 0 failures).

- [ ] **Step 7: Commit**

```bash
git add web/app/controllers/control_center/base_controller.rb web/config/routes.rb web/app/controllers/control_center/statistics_controller.rb web/app/views/control_center/statistics web/test/integration/control_center/tabs_test.rb
git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m "Add Control Center Statistics tab with job analytics tiles and charts"
```

---

### Task 8: Full-suite green + security/verification pass

**Files:** none (verification).

- [ ] **Step 1: Run the whole suite (excluding the known-broken runner test)**

Run: `cd web && files=$(find test -name '*_test.rb' ! -path 'test/integration/api/runner/*'); bin/rails test $files`
Expected: all pass, including the new TemplateYaml, JobStats, templates-YAML, stats, charts, and tabs tests. Note any pre-existing unrelated failure without fixing it here.

- [ ] **Step 2: Confirm no unsafe YAML load anywhere in Control Center**

Run: `cd web && grep -rnE "YAML\.load|Psych\.load|unsafe_load" app/services/control_center app/controllers/api/v1/control_center`
Expected: no matches (only `YAML.safe_load` in `template_yaml.rb`).

- [ ] **Step 3: Confirm the importmap still resolves the templates controller**

Run: `cd web && bin/rails runner 'puts Rails.application.importmap.to_json(resolver: ApplicationController.helpers).scan(%r{controllers/control_center_templates_controller}).first'`
Expected: prints `controllers/control_center_templates_controller`.

- [ ] **Step 4: Manual verification (user runs Docker)**

Document for the user: on `/control_center` → New template → switch to **YAML** → paste a cmdscript template → live "valid" badge appears and Save enables; **Upload .yaml** loads a file into the editor; a malformed or non-allowlisted YAML shows inline errors and disables Save. The **Statistics** tab shows job tiles, the status donut, most-used templates, per-queue bars, and the 30-day chart.

---

## Self-Review

**Spec coverage:**
- Raw YAML authoring → Tasks 1 (parser), 2 (API), 3 (UI YAML mode).
- File upload → Task 3 (client `FileReader` into the editor; server caps via Task 1/2).
- Robust YAML validation while writing → Tasks 1 (schema+safe parse), 2 (`validate_yaml` + allowlist), 3 (debounced live validation + valid badge/errors).
- Statistics (jobs sent, most-used templates, general) → Tasks 4 (`JobStats`), 5 (chart geometry), 6 (stats API), 7 (Statistics tab).
- Security (safe_load, size cap, allowlist unbypassable, no server file storage, read-only parametrized stats) → Tasks 1, 2, 4, and verification Task 8 Step 2.
- Neat UI/UX + isolation → Task 3 (mode toggle/upload/debounce), Task 7 (tiles/charts/empty states), monochrome+functional-color throughout.

**Placeholder scan:** none — every step has concrete code/commands.

**Type consistency:** `TemplateYaml.parse -> [attrs_or_nil, errors]` consumed identically in Tasks 2/3. `JobStats.dashboard` shape (`totals`/`by_status`/`top_templates`/`by_queue`/`daily`) consumed by Tasks 6 (JSON) and 7 (views) and matches the `ChartsHelper` inputs (`bar_list_rows`/`daily_bars`/`donut_segments`) from Task 5. Stimulus identifier `control-center-templates` with new value `validateYamlUrl` and targets consistent between the shell (Task 3 Step 3) and controller (Step 4). Route helpers `validate_yaml_api_v1_control_center_templates_path`, `api_v1_control_center_stats_path`, `control_center_statistics_path` used consistently.

**Deviation from spec:** none. Workflow-kind YAML remains out of scope as stated.
```
