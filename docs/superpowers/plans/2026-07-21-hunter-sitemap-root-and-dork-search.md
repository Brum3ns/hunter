# Hunter Sitemap Root Exclusion and Dork Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hide `/` sitemap endpoints from default counts and trees while adding an explicit root opt-in and a safe, PostgreSQL-backed dork search.

**Architecture:** A sitemap-specific parser builds a small `Term`/`And`/`Or` AST whose mapper emits Arel predicates over endpoints joined to targets. `Sitemap::EndpointFilter` remains the single relation boundary used by grouped origin counts and lazy trees, so root and search behavior cannot diverge.

**Tech Stack:** Ruby 3.3.6, Rails 8.1, Active Record/Arel, PostgreSQL, ERB/Tailwind, Turbo, Minitest.

## Global Constraints

- Follow `docs/superpowers/specs/2026-07-21-hunter-sitemap-root-and-dork-search-design.md` exactly.
- No schema, API, Mongo, or synchronization changes.
- Root means `sitemap_endpoints.path == "/"` exactly.
- The checkbox broadens root eligibility; `root:yes` is an exact root predicate.
- Dork values must reach SQL only through quoted Arel/Active Record nodes.
- Preserve all unrelated dirty-worktree changes.
- Do not commit: repository instructions allow commits only when explicitly requested.

---

### Task 1: Sitemap search parser

**Files:**
- Create: `web/app/services/sitemap/search_parser.rb`
- Create: `web/test/services/sitemap/search_parser_test.rb`

**Interfaces:**
- Consumes: raw `q` string.
- Produces: `Sitemap::SearchParser.call(q) -> Result(free_text:, expression:)`.
- Produces AST nodes from `Sitemap::DorkExpression::{Term, And, Or}`.

- [ ] **Step 1: Write the failing parser tests**

Create `web/test/services/sitemap/search_parser_test.rb`:

```ruby
require "test_helper"

class Sitemap::SearchParserTest < ActiveSupport::TestCase
  Term = Sitemap::DorkExpression::Term
  And_ = Sitemap::DorkExpression::And
  Or_  = Sitemap::DorkExpression::Or

  def parse(query) = Sitemap::SearchParser.call(query)

  test "plain text has no expression" do
    result = parse("admin login")
    assert_equal "admin login", result.free_text
    assert_nil result.expression
  end

  test "free text and quoted dorks can mix" do
    result = parse('admin content_type:"application/json"')
    assert_equal "admin", result.free_text
    assert_equal Term.new(key: "content_type", op: nil, value: "application/json"), result.expression
  end

  test "adjacent terms imply AND and capture comparisons" do
    result = parse("method:POST status:>=400")
    assert_equal And_.new(children: [
      Term.new(key: "method", op: nil, value: "POST"),
      Term.new(key: "status", op: ">=", value: "400")
    ]), result.expression
  end

  test "AND binds tighter than OR and parentheses override it" do
    result = parse("root:yes OR method:POST AND status:500")
    assert_instance_of Or_, result.expression
    assert_instance_of And_, result.expression.children.last

    grouped = parse("(root:yes OR method:POST) AND status:500")
    assert_instance_of And_, grouped.expression
    assert_instance_of Or_, grouped.expression.children.first
  end

  test "symbolic boolean operators are accepted" do
    result = parse("method:POST && (status:200 || status:201)")
    assert_instance_of And_, result.expression
    assert_instance_of Or_, result.expression.children.last
  end

  test "unknown keys and orphan operators remain free text" do
    result = parse("cats or dogs unknown:value")
    assert_equal "cats or dogs unknown:value", result.free_text
    assert_nil result.expression
  end

  test "every public key is recognized" do
    %w[host origin program path url content_type method scheme port status length has_query root seen].each do |key|
      assert_instance_of Term, parse("#{key}:value").expression, key
    end
  end
end
```

- [ ] **Step 2: Run the parser test and verify RED**

Run through the available Rails runtime:

```bash
cd web && bin/rails test test/services/sitemap/search_parser_test.rb
```

Expected: failure because `Sitemap::SearchParser` and/or `Sitemap::DorkExpression` does not exist.

- [ ] **Step 3: Add the minimal AST value types and parser**

Create `web/app/services/sitemap/search_parser.rb` with the existing Hunter grammar:

```ruby
require "strscan"

module Sitemap
  class SearchParser
    Result = Struct.new(:free_text, :expression, keyword_init: true)
    KEYS = %w[
      host origin program path url content_type method scheme
      port status length has_query root seen
    ].freeze
    OPERAND_TYPES = %i[term lparen rparen].freeze

    def self.call(query) = new(query).call

    def initialize(query)
      @query = query.to_s
    end

    def call
      cooked = demote_orphan_operators(tokenize(@query))
      free_text = cooked.select { |token| token[0] == :text }.map { |token| token[1] }.join(" ").strip
      @tokens = cooked.reject { |token| token[0] == :text }
      @position = 0
      Result.new(free_text: free_text, expression: parse_or)
    end

    private

    def tokenize(string)
      scanner = StringScanner.new(string)
      tokens = []
      until scanner.eos?
        if scanner.scan(/\s+/)
          next
        elsif scanner.scan(/\(/)
          tokens << [:lparen]
        elsif scanner.scan(/\)/)
          tokens << [:rparen]
        elsif scanner.scan(/(?:&&|\band\b)/i)
          tokens << [:and]
        elsif scanner.scan(/(?:\|\||\bor\b)/i)
          tokens << [:or]
        elsif scanner.scan(/(\w+):(>=|<=|>|<)?(?:"([^"]+)"|([^\s()]+))/)
          key = scanner[1].downcase
          token = [:term, key, scanner[2], scanner[3] || scanner[4]]
          tokens << (KEYS.include?(key) ? token : [:text, scanner.matched])
        else
          word = scanner.scan(/\S+/)
          tokens << [:text, word] if word
        end
      end
      tokens
    end

    def demote_orphan_operators(tokens)
      tokens.each_with_index.map do |token, index|
        next token unless %i[and or].include?(token[0])
        previous = index.positive? ? tokens[index - 1] : nil
        following = tokens[index + 1]
        operand_like?(previous) && operand_like?(following) ? token : [:text, token[0].to_s]
      end
    end

    def operand_like?(token) = token && OPERAND_TYPES.include?(token[0])
    def peek = @tokens[@position]
    def at?(type) = peek && peek[0] == type
    def consume = @tokens[@position].tap { @position += 1 }

    def parse_or
      left = parse_and
      return unless left
      while at?(:or)
        consume
        right = parse_and
        break unless right
        left = combine(DorkExpression::Or, left, right)
      end
      left
    end

    def parse_and
      children = []
      loop do
        consume if at?(:and)
        node = parse_primary
        break unless node
        children << node
        break unless at?(:and) || at?(:term) || at?(:lparen)
      end
      return if children.empty?
      children.one? ? children.first : DorkExpression::And.new(children: children)
    end

    def parse_primary
      return unless peek
      if at?(:lparen)
        consume
        expression = parse_or
        consume if at?(:rparen)
        expression
      elsif at?(:term)
        _, key, operator, value = consume
        DorkExpression::Term.new(key: key, op: operator, value: value)
      end
    end

    def combine(type, left, right)
      left_children = left.is_a?(type) ? left.children : [left]
      right_children = right.is_a?(type) ? right.children : [right]
      type.new(children: left_children + right_children)
    end
  end
end
```

Create `web/app/services/sitemap/dork_expression.rb` initially with only the value types needed by parser tests:

```ruby
module Sitemap
  module DorkExpression
    Term = Struct.new(:key, :op, :value, keyword_init: true)
    And  = Struct.new(:children, keyword_init: true)
    Or   = Struct.new(:children, keyword_init: true)
  end
end
```

- [ ] **Step 4: Run parser tests and verify GREEN**

Run the Task 1 test command. Expected: all parser tests pass.

---

### Task 2: Arel-backed dork expressions

**Files:**
- Modify: `web/app/services/sitemap/dork_expression.rb`
- Create: `web/test/services/sitemap/dork_expression_test.rb`

**Interfaces:**
- Produces: every expression node responds to `to_arel` and `includes_positive_root?`.
- Produces: `Sitemap::DorkExpression::Mapper.free_text_arel(text)`.

- [ ] **Step 1: Write failing database-backed predicate tests**

Create two active targets/endpoints per test, parse queries with
`Sitemap::SearchParser`, and apply `expression.to_arel` to
`Sitemap::Endpoint.active.joins(:target)`. Cover:

```ruby
test "all public keys map to their intended columns" do
  queries = %w[
    host:api.example.com origin:api.example.com program:acme path:admin
    url:token content_type:json method:post scheme:https port:443
    status:503 length:2048 has_query:yes root:no seen:2026-07-10
  ]
  queries.each do |query|
    assert_includes search(query), @hit, query
    assert_not_includes search(query), @miss, query
  end
end

test "wildcards are anchored and SQL wildcard characters stay literal" do
  assert_equal [@hit], search("host:*.example.com")
  assert_equal [@hit], search('path:"/admin/100%_safe"')
end

test "numeric comparisons compose" do
  assert_equal [@hit], search("status:>=500 length:>1024")
end

test "root predicates and positive-root metadata work through nesting" do
  root = endpoint!(target: @hit.target, path: "/")
  expression = parse("root:yes OR path:/admin").expression
  assert expression.includes_positive_root?
  assert_equal [@hit, root].sort_by(&:id), relation.where(expression.to_arel).sort_by(&:id)
  refute parse("root:no").expression.includes_positive_root?
end

test "AND binds tighter than OR in generated predicates" do
  assert_equal [@hit], search("root:yes OR method:POST AND status:503")
end

test "invalid typed values safely match nothing" do
  %w[status:nope length:1.2 has_query:maybe root:maybe seen:yesterday].each do |query|
    assert_empty search(query), query
  end
end
```

The fixture helper must create complete `Sitemap::Target` and
`Sitemap::Endpoint` records, including unique URL digests. Set `@hit` to a POST
503 `/admin/100%_safe?token=1` endpoint on `api.example.com`, and `@miss` to a
GET 200 `/public` endpoint on `other.test`.

- [ ] **Step 2: Run predicate tests and verify RED**

```bash
cd web && bin/rails test test/services/sitemap/dork_expression_test.rb
```

Expected: failure because the AST nodes do not yet emit Arel predicates.

- [ ] **Step 3: Implement the mapper and expression composition**

Expand `Sitemap::DorkExpression` with:

```ruby
require "date"

module Sitemap
  module DorkExpression
    Term = Struct.new(:key, :op, :value, keyword_init: true) do
      def to_arel = Mapper.to_arel(key, op, value)
      def includes_positive_root? = key == "root" && Mapper.boolean(value) == true
    end

    And = Struct.new(:children, keyword_init: true) do
      def to_arel = Mapper.combine(children.map(&:to_arel), :and)
      def includes_positive_root? = children.any?(&:includes_positive_root?)
    end

    Or = Struct.new(:children, keyword_init: true) do
      def to_arel = Mapper.combine(children.map(&:to_arel), :or)
      def includes_positive_root? = children.any?(&:includes_positive_root?)
    end

    module Mapper
      TEXT_FIELDS = {
        "host" => Sitemap::Target.arel_table[:host],
        "origin" => Sitemap::Target.arel_table[:origin],
        "program" => Sitemap::Target.arel_table[:program],
        "path" => Sitemap::Endpoint.arel_table[:path],
        "url" => Sitemap::Endpoint.arel_table[:url],
        "content_type" => Sitemap::Endpoint.arel_table[:content_type]
      }.freeze
      EXACT_FIELDS = {
        "method" => Sitemap::Endpoint.arel_table[:method],
        "scheme" => Sitemap::Target.arel_table[:scheme]
      }.freeze
      NUMBER_FIELDS = {
        "port" => Sitemap::Target.arel_table[:port],
        "status" => Sitemap::Endpoint.arel_table[:status_code],
        "length" => Sitemap::Endpoint.arel_table[:content_length]
      }.freeze
      RANGE_METHODS = { ">" => :gt, ">=" => :gteq, "<" => :lt, "<=" => :lteq }.freeze
      TRUE_VALUES = %w[yes true 1 on].freeze
      FALSE_VALUES = %w[no false 0 off].freeze

      module_function

      def to_arel(key, op, value)
        return text_arel(TEXT_FIELDS.fetch(key), value) if TEXT_FIELDS.key?(key)
        return exact_arel(EXACT_FIELDS.fetch(key), value) if EXACT_FIELDS.key?(key)
        return number_arel(NUMBER_FIELDS.fetch(key), op, value) if NUMBER_FIELDS.key?(key)

        case key
        when "has_query" then boolean_arel(Sitemap::Endpoint.arel_table[:url].matches("%?%", nil, false), value)
        when "root" then boolean_arel(Sitemap::Endpoint.arel_table[:path].eq("/"), value)
        when "seen" then date_arel(Sitemap::Endpoint.arel_table[:last_seen_at], op, value)
        else false_arel
        end
      end

      def free_text_arel(value)
        predicates = TEXT_FIELDS.values_at("host", "origin", "program", "path", "url", "content_type")
                                .map { |field| field.matches("%#{escape(value)}%", nil, false) }
        combine(predicates, :or)
      end

      def combine(predicates, operator)
        predicates.reduce do |left, right|
          operator == :and ? left.and(right) : left.or(right)
        end || false_arel
      end

      def boolean(value)
        normalized = value.to_s.downcase
        return true if TRUE_VALUES.include?(normalized)
        return false if FALSE_VALUES.include?(normalized)
      end

      def false_arel = Arel::Nodes::Equality.new(Arel::Nodes.build_quoted(1), Arel::Nodes.build_quoted(0))

      def text_arel(field, value)
        field.matches(pattern(value, substring: true), nil, false)
      end

      def exact_arel(field, value)
        return field.matches(pattern(value, substring: false), nil, false) if value.to_s.include?("*")
        Arel::Nodes::NamedFunction.new("LOWER", [field]).eq(value.to_s.downcase)
      end

      def number_arel(field, op, value)
        number = Integer(value, 10)
        op.present? ? field.public_send(RANGE_METHODS.fetch(op), number) : field.eq(number)
      rescue ArgumentError, KeyError
        false_arel
      end

      def boolean_arel(predicate, value)
        parsed = boolean(value)
        return false_arel if parsed.nil?
        parsed ? predicate : Arel::Nodes::Not.new(predicate)
      end

      def date_arel(field, op, value)
        date = Date.iso8601(value.to_s)
        day_start = Time.utc(date.year, date.month, date.day)
        next_day = day_start + 86_400
        case op
        when nil then field.gteq(day_start).and(field.lt(next_day))
        when ">=" then field.gteq(day_start)
        when ">" then field.gteq(next_day)
        when "<" then field.lt(day_start)
        when "<=" then field.lt(next_day)
        else false_arel
        end
      rescue Date::Error
        false_arel
      end

      def pattern(value, substring:)
        raw = value.to_s
        return "%#{escape(raw)}%" if substring && !raw.include?("*")
        raw.split("*", -1).map { |part| escape(part) }.join("%")
      end

      def escape(value) = ActiveRecord::Base.sanitize_sql_like(value.to_s)
    end
  end
end
```

If Rails' current Arel API differs, preserve the public interfaces and use the
equivalent quoted node; do not interpolate user input into SQL.

- [ ] **Step 4: Run parser and predicate tests and verify GREEN**

```bash
cd web && bin/rails test test/services/sitemap/search_parser_test.rb test/services/sitemap/dork_expression_test.rb
```

Expected: all tests pass with no SQL errors.

---

### Task 3: Root and search composition in `EndpointFilter`

**Files:**
- Modify: `web/app/services/sitemap/endpoint_filter.rb`
- Modify: `web/test/services/sitemap/endpoint_filter_test.rb`

**Interfaces:**
- `EndpointFilter.apply(scope, params, free_text: nil, expression: nil, include_root: nil) -> ActiveRecord::Relation`.

- [ ] **Step 1: Add failing filter tests**

Replace the existing “blank params return the scope unfiltered” assertion with
one proving non-root records remain while `/` is excluded. Add tests for:

```ruby
test "root is excluded by default" do
  root = ep!(path: "/")
  child = ep!(path: "/child")
  assert_equal [child], apply({})
  assert_not_includes apply({}), root
end

test "include_root keeps root and non-root endpoints" do
  root = ep!(path: "/")
  child = ep!(path: "/child")
  assert_equal [root, child].sort_by(&:id), apply({}, include_root: "1").sort_by(&:id)
end

test "positive root dork opts in and remains a root predicate" do
  root = ep!(path: "/")
  ep!(path: "/child")
  parsed = Sitemap::SearchParser.call("root:yes")
  assert_equal [root], apply({}, expression: parsed.expression)
end

test "free text and dorks search joined target and endpoint fields" do
  admin = ep!(path: "/admin", method: "POST")
  ep!(path: "/public")
  assert_equal [admin], apply({}, free_text: "admin")
  parsed = Sitemap::SearchParser.call("host:ex.com method:POST")
  assert_equal [admin], apply({}, expression: parsed.expression)
end
```

Update the test helper to forward keyword arguments:

```ruby
def apply(params, **options)
  Sitemap::EndpointFilter.apply(Sitemap::Endpoint.active, params, **options).to_a
end
```

- [ ] **Step 2: Run filter tests and verify RED**

```bash
cd web && bin/rails test test/services/sitemap/endpoint_filter_test.rb
```

Expected: default root and keyword-argument tests fail.

- [ ] **Step 3: Implement minimal shared composition**

Change `apply` to:

```ruby
def apply(scope, params, free_text: nil, expression: nil, include_root: nil)
  params ||= {}
  allow_root = truthy?(include_root) || expression&.includes_positive_root?
  scope = scope.where.not(path: "/") unless allow_root
  scope = by_methods(scope, params[:methods])
  scope = by_status(scope, params[:status])
  scope = by_path(scope, params[:path])
  scope = by_has_query(scope, params[:has_query])
  scope = by_content_type(scope, params[:content_type])

  if free_text.present? || expression
    scope = scope.joins(:target)
    scope = scope.where(DorkExpression::Mapper.free_text_arel(free_text)) if free_text.present?
    scope = scope.where(expression.to_arel) if expression
  end
  scope
end

def truthy?(value) = TRUTHY.include?(value.to_s.downcase)
private_class_method :truthy?
```

Reuse `truthy?` from `by_has_query` so checkbox semantics remain centralized.

- [ ] **Step 4: Run all sitemap service tests and verify GREEN**

```bash
cd web && bin/rails test test/services/sitemap
```

Expected: all sitemap service tests pass.

---

### Task 4: Controller data flow and search/filter UI

**Files:**
- Modify: `web/app/controllers/sitemap/origins_controller.rb`
- Modify: `web/app/views/sitemap/origins/index.html.erb`
- Modify: `web/app/views/sitemap/origins/_filters.html.erb`
- Modify: `web/test/integration/sitemap/origins_test.rb`
- Modify: `web/test/integration/sitemap/tree_test.rb`

**Interfaces:**
- `q`, endpoint filters, and `include_root` reach both grouped counts and tree relations.
- `@tree_filter` is the exact parameter hash forwarded to lazy frames.

- [ ] **Step 1: Add failing root/count/search integration tests**

Extend endpoint test helpers to accept explicit `url` and `content_type` when
needed. Add tests proving:

```ruby
test "root-only origin is hidden and root does not increment default counts" do
  root_only = target!(host: "root.only"); endpoint!(root_only, "/")
  mixed = target!(host: "mixed.host"); endpoint!(mixed, "/"); endpoint!(mixed, "/api")
  get sitemap_root_path
  assert_no_match "root.only", response.body
  assert_select "turbo-frame#origin_tree_#{mixed.id}", count: 1
  assert_select "li[data-node]", text: /mixed\.host:443.*1/m
end

test "include_root shows root-only origins and is forwarded to the tree" do
  target = target!(host: "root.only"); endpoint!(target, "/")
  get sitemap_root_path(include_root: "1")
  assert_match "root.only", response.body
  assert_select "input[name=include_root][checked]"
  assert_select "turbo-frame#origin_tree_#{target.id}[data-src=?]",
                sitemap_origin_tree_path(target, include_root: "1")
end

test "root dork selects root and is forwarded to the tree" do
  target = target!(host: "root.only"); endpoint!(target, "/")
  get sitemap_root_path(q: "root:yes")
  assert_match "root.only", response.body
  assert_select "turbo-frame#origin_tree_#{target.id}[data-src=?]",
                sitemap_origin_tree_path(target, q: "root:yes")
end

test "free text and endpoint dorks filter origin counts" do
  target = target!(host: "api.example.com")
  endpoint!(target, "/admin", method: "POST", status: 503)
  endpoint!(target, "/public", method: "GET", status: 200)
  get sitemap_root_path(q: "host:api.example.com method:POST status:>=500")
  assert_match "api.example.com", response.body
  assert_select "li[data-node]", text: /api\.example\.com:443.*1/m
end

test "search form preserves active sidebar filters and renders syntax help" do
  target = target!(host: "api.example.com"); endpoint!(target, "/admin", method: "POST")
  get sitemap_root_path(methods: ["POST"], status: ["2"], include_root: "1", min_count: 2)
  assert_select "form[data-sitemap-search] input[type=hidden][name='methods[]'][value=POST]"
  assert_select "form[data-sitemap-search] input[type=hidden][name='status[]'][value='2']"
  assert_select "form[data-sitemap-search] input[type=hidden][name=include_root][value='1']"
  assert_select "button[aria-label='Search syntax help']"
  assert_match "root:yes", response.body
end
```

Extend tree integration tests to prove `/` is absent by default and present for
both `include_root=1` and `q=root:yes`.

- [ ] **Step 2: Run focused integration tests and verify RED**

```bash
cd web && bin/rails test test/integration/sitemap/origins_test.rb test/integration/sitemap/tree_test.rb
```

Expected: failures for root exclusion, dork parsing, parameter forwarding, and
new UI controls.

- [ ] **Step 3: Route both controller actions through one filtering helper**

In `OriginsController`:

```ruby
def index
  @q = params[:q].to_s.strip
  @program = params[:program].presence
  @scheme = params[:scheme].presence
  raw_min = params[:min_count]
  @min_count = raw_min.present? ? [raw_min.to_i, 0].max : 1

  targets = Sitemap::Target.active.order(:host, :port)
  targets = targets.where(program: @program) if @program
  targets = targets.where(scheme: @scheme) if @scheme
  candidates = targets.to_a

  @counts = filtered_endpoints(Sitemap::Endpoint.active.where(target_id: candidates.map(&:id)))
            .group(:target_id).count
  @targets = candidates.select do |target|
    @counts[target.id].to_i >= @min_count && (@q.blank? || @counts.key?(target.id))
  end

  @programs = Sitemap::Target.active.distinct.pluck(:program).compact.sort
  @method_options = Sitemap::Endpoint.active.distinct.pluck(:method).compact.sort
  @filter = endpoint_filter_params.to_h
  @tree_filter = @filter.dup
  @tree_filter["q"] = @q if @q.present?
end

def tree
  @target = Sitemap::Target.active.find_by(id: params[:id])
  return head :not_found unless @target
  @nodes = Sitemap::Tree.build(filtered_endpoints(@target.endpoints.active))
  render :tree
end

def filtered_endpoints(scope)
  parsed = Sitemap::SearchParser.call(params[:q])
  Sitemap::EndpointFilter.apply(
    scope,
    endpoint_filter_params,
    free_text: parsed.free_text,
    expression: parsed.expression,
    include_root: params[:include_root]
  )
end

def endpoint_filter_params
  params.permit(:path, :has_query, :content_type, :include_root, methods: [], status: [])
end
```

Render origin rows with `filter: @tree_filter`.

- [ ] **Step 4: Implement the dork search and root-filter UI**

In `index.html.erb`, replace the simple search form with an explicit GET form
marked `data-sitemap-search`, preserve every current filter in hidden inputs,
and add the same question-mark hover/focus help panel used by Programs and
Vulnerabilities. The cheatsheet must enumerate all public keys and the approved
combination examples. Keep the left-column layout and existing styles.

In `_filters.html.erb`, add:

```erb
<label class="inline-flex items-center gap-1">
  <input type="checkbox" name="include_root" value="1" <%= "checked" if @filter["include_root"].present? %> />
  <span>Include <code>/</code> root</span>
</label>
```

The filter form already preserves `q`; retain that behavior.

- [ ] **Step 5: Run focused integration and service tests and verify GREEN**

```bash
cd web && bin/rails test test/services/sitemap test/integration/sitemap
```

Expected: all sitemap service and integration tests pass.

---

### Task 5: Regression and safety verification

**Files:**
- Verify only; modify prior task files only if a test exposes a scoped defect.

- [ ] **Step 1: Run formatting/static checks on changed Ruby files**

```bash
cd web && bin/rubocop app/services/sitemap/search_parser.rb app/services/sitemap/dork_expression.rb app/services/sitemap/endpoint_filter.rb app/controllers/sitemap/origins_controller.rb test/services/sitemap/search_parser_test.rb test/services/sitemap/dork_expression_test.rb test/services/sitemap/endpoint_filter_test.rb test/integration/sitemap/origins_test.rb test/integration/sitemap/tree_test.rb
```

Expected: exit 0. If `bin/rubocop` is unavailable in the runtime, run
`bundle exec rubocop` with the same paths.

- [ ] **Step 2: Run the full Rails test suite**

```bash
cd web && bin/rails test
```

Expected: exit 0 with zero failures and zero errors.

- [ ] **Step 3: Verify production diff scope and whitespace**

```bash
git diff --check
git status --short
git diff -- web/app/services/sitemap web/app/controllers/sitemap/origins_controller.rb web/app/views/sitemap/origins web/test/services/sitemap web/test/integration/sitemap docs/superpowers/specs/2026-07-21-hunter-sitemap-root-and-dork-search-design.md docs/superpowers/plans/2026-07-21-hunter-sitemap-root-and-dork-search.md
```

Expected: no whitespace errors; only the intended sitemap/docs files differ in
the task's diff. Leave all unrelated pre-existing changes untouched.

- [ ] **Step 4: Do not commit**

Report the verified commands and changed files to the user. A commit is a
separate action requiring explicit authorization.
