# Vulnerability Page Robust Filtering — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port scope-ui's robust filtering (dork query language + faceted sidebar + chips + sort) to the Hunter vulnerabilities page, adapted to the vulnerability MongoDB JSON.

**Architecture:** Faithful port of scope's service shape into `Vulnerabilities::` — `SearchParser` → `DorkExpression` (AST with `to_mongo` + `evaluate`) → `Query` (Mongo match doc + `$facet` counts + pagination, falling back to an in-memory `Filter` + `Sort`). The `OverviewController` switches from `MongoSource.all` to `Query`, and the overview views gain a facet sidebar, active-filter chips, and a sort control.

**Tech Stack:** Ruby 3.3, Rails 8, MongoDB (`mongo` gem via `HunterMongo`), Tailwind v4, Stimulus/Turbo, Minitest (Mongo doubled in tests via `stub_methods`).

## Global Constraints

- Ruby module namespace is `Hunter`; module code lives under `web/`.
- Keep the vulnerability module **isolated**: new code lives under `app/services/vulnerabilities/`, `app/views/vulnerabilities/overview/`, and `VulnerabilitiesHelper`. No cross-module touch-points.
- Mongo **reads swallow `Mongo::Error`** to an empty/degraded result; never crash the page.
- Tests never require live Mongo — double the collection with the `stub_methods` helper in `web/test/test_helper.rb`.
- Design language is **monochrome**; the only pre-existing color exception is the severity/status badge ramps in `VulnerabilitiesHelper`. Do not introduce new color.
- Commit author is `Claude <noreply@anthropic.com>`; commit messages are a **single sentence**. Commit commands below use per-invocation `-c` overrides.
- Run tests from `web/`: `bin/rails test <path>`.
- `to_mongo` and `evaluate` for every dork key MUST stay in parity — exact keys match case-insensitively on both paths.

---

### Task 1: `Vulnerabilities::DorkExpression` (AST + Mapper)

The core: AST nodes and the `Mapper` that owns per-key semantics on both the Mongo and in-memory paths. No parser yet — tests build `Term`/`And`/`Or` directly.

**Files:**
- Create: `web/app/services/vulnerabilities/dork_expression.rb`
- Test: `web/test/services/vulnerabilities/dork_expression_test.rb`

**Interfaces:**
- Consumes: `Vulnerability` PORO (`web/app/models/vulnerability.rb`) — `#metadata`, `#report`, `#finding`, `#target`, `#poc` each return a `Hash`.
- Produces:
  - `Vulnerabilities::DorkExpression::Term.new(key:, op:, value:)` with `#to_mongo → Hash|nil` and `#evaluate(vuln) → Boolean`.
  - `Vulnerabilities::DorkExpression::And.new(children:)` / `Or.new(children:)` with the same two methods.
  - `Vulnerabilities::DorkExpression::Mapper.to_mongo(key, op, value) → Hash|nil` and `.evaluate(vuln, key, op, value) → Boolean`.

- [ ] **Step 1: Write the failing test**

```ruby
# web/test/services/vulnerabilities/dork_expression_test.rb
require "test_helper"

class Vulnerabilities::DorkExpressionTest < ActiveSupport::TestCase
  DE = Vulnerabilities::DorkExpression

  def vuln(overrides = {})
    base = {
      "metadata" => { "program" => "Mirakl Helpdesk", "asset" => "helpdesk", "tool" => "nuclei", "date" => "2026-06-30" },
      "report"   => { "status" => "new", "submitted" => false },
      "finding"  => { "name" => "Header Fuzzer", "type" => "http", "cwe" => "CWE-20", "severity" => "low", "tags" => ["fuzz", "headers"] },
      "target"   => { "host" => "helpdesk.mirakl.net", "url" => "https://helpdesk.mirakl.net", "ip" => "216.198.53.11", "port" => "443", "method" => "GET" },
      "poc"      => { "confidence" => "high" }
    }
    Vulnerability.new(base.deep_merge(overrides))
  end

  # key, op, value, mongo clause, [vuln overrides that MATCH], [vuln overrides that DON'T]
  CASES = [
    ["severity", nil, "LOW",       { "finding.severity" => { "$regex" => "\\Alow\\z", "$options" => "i" } }, {}, { "finding" => { "severity" => "high" } }],
    ["status",   nil, "new",       { "report.status"    => { "$regex" => "\\Anew\\z", "$options" => "i" } }, {}, { "report" => { "status" => "close" } }],
    ["tool",     nil, "nuclei",    { "metadata.tool"    => { "$regex" => "\\Anuclei\\z", "$options" => "i" } }, {}, { "metadata" => { "tool" => "nikto" } }],
    ["type",     nil, "http",      { "finding.type"     => { "$regex" => "\\Ahttp\\z", "$options" => "i" } }, {}, { "finding" => { "type" => "dns" } }],
    ["cwe",      nil, "cwe-20",    { "finding.cwe"      => { "$regex" => "\\Acwe\\-20\\z", "$options" => "i" } }, {}, { "finding" => { "cwe" => "CWE-79" } }],
    ["ip",       nil, "216.198.53.11", { "target.ip"    => { "$regex" => "\\A216\\.198\\.53\\.11\\z", "$options" => "i" } }, {}, { "target" => { "ip" => "1.1.1.1" } }],
    ["port",     nil, "443",       { "target.port"      => { "$regex" => "\\A443\\z", "$options" => "i" } }, {}, { "target" => { "port" => "80" } }],
    ["method",   nil, "get",       { "target.method"    => { "$regex" => "\\Aget\\z", "$options" => "i" } }, {}, { "target" => { "method" => "POST" } }],
    ["confidence", nil, "high",    { "poc.confidence"   => { "$regex" => "\\Ahigh\\z", "$options" => "i" } }, {}, { "poc" => { "confidence" => "low" } }],
    ["tag",      nil, "fuzz",      { "finding.tags"     => { "$regex" => "\\Afuzz\\z", "$options" => "i" } }, {}, { "finding" => { "tags" => ["xss"] } }],
    ["program",  nil, "mirakl",    { "metadata.program" => { "$regex" => "mirakl", "$options" => "i" } }, {}, { "metadata" => { "program" => "Acme" } }],
    ["asset",    nil, "help",      { "metadata.asset"   => { "$regex" => "help", "$options" => "i" } }, {}, { "metadata" => { "asset" => "api" } }],
    ["name",     nil, "fuzzer",    { "finding.name"     => { "$regex" => "fuzzer", "$options" => "i" } }, {}, { "finding" => { "name" => "SQLi" } }],
    ["host",     nil, "mirakl.net", { "target.host"     => { "$regex" => "mirakl\\.net", "$options" => "i" } }, {}, { "target" => { "host" => "example.com" } }],
    ["url",      nil, "https",     { "target.url"       => { "$regex" => "https", "$options" => "i" } }, {}, { "target" => { "url" => "" } }],
    ["submitted", nil, "no",       { "report.submitted" => false }, {}, { "report" => { "submitted" => true } }],
    ["date",     ">=", "2026-06-01", { "metadata.date"  => { "$gte" => "2026-06-01" } }, {}, { "metadata" => { "date" => "2026-01-01" } }],
    ["date",     "<=", "2026-06-01", { "metadata.date"  => { "$lte" => "2026-06-01" } }, { "metadata" => { "date" => "2026-05-01" } }, {}]
  ].freeze

  test "each key emits the expected mongo clause" do
    CASES.each do |key, op, value, clause, _match, _no|
      assert_equal clause, DE::Mapper.to_mongo(key, op, value), "to_mongo(#{key})"
    end
  end

  test "evaluate agrees with to_mongo intent for matching and non-matching docs" do
    CASES.each do |key, op, value, _clause, match_over, no_over|
      assert DE::Mapper.evaluate(vuln(match_over), key, op, value), "expected #{key}:#{value} to match"
      assert_not DE::Mapper.evaluate(vuln(no_over), key, op, value), "expected #{key}:#{value} to NOT match"
    end
  end

  test "unknown key returns nil clause and false evaluation" do
    assert_nil DE::Mapper.to_mongo("bogus", nil, "x")
    assert_not DE::Mapper.evaluate(vuln, "bogus", nil, "x")
  end

  test "And/Or compose to_mongo and evaluate" do
    hi  = DE::Term.new(key: "severity", op: nil, value: "low")
    tool = DE::Term.new(key: "tool", op: nil, value: "nuclei")
    andx = DE::And.new(children: [hi, tool])
    assert_equal({ "$and" => [hi.to_mongo, tool.to_mongo] }, andx.to_mongo)
    assert andx.evaluate(vuln)
    orx = DE::Or.new(children: [DE::Term.new(key: "tool", op: nil, value: "nikto"), tool])
    assert orx.evaluate(vuln)
    assert_equal tool.to_mongo, DE::And.new(children: [tool]).to_mongo, "single child unwraps"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/vulnerabilities/dork_expression_test.rb`
Expected: FAIL — `uninitialized constant Vulnerabilities::DorkExpression`.

- [ ] **Step 3: Write the implementation**

```ruby
# web/app/services/vulnerabilities/dork_expression.rb
module Vulnerabilities
  # AST nodes the search parser emits, plus the Mapper that owns all per-key
  # semantics. Every supported dork key has two implementations side by side in
  # Mapper: `to_mongo` for the indexed Mongo path and `evaluate` for the
  # in-memory fallback. They live together so a key cannot be added on one path
  # without the other — parity is enforced by the tests.
  module DorkExpression
    Term = Struct.new(:key, :op, :value, keyword_init: true) do
      def to_mongo         = Mapper.to_mongo(key, op, value)
      def evaluate(vuln)   = Mapper.evaluate(vuln, key, op, value)
    end

    And = Struct.new(:children, keyword_init: true) do
      def to_mongo
        clauses = children.map(&:to_mongo).compact
        return nil           if clauses.empty?
        return clauses.first if clauses.size == 1
        { "$and" => clauses }
      end
      def evaluate(vuln) = children.all? { |c| c.evaluate(vuln) }
    end

    Or = Struct.new(:children, keyword_init: true) do
      def to_mongo
        clauses = children.map(&:to_mongo).compact
        return nil           if clauses.empty?
        return clauses.first if clauses.size == 1
        { "$or" => clauses }
      end
      def evaluate(vuln) = children.any? { |c| c.evaluate(vuln) }
    end

    module Mapper
      BOOL_TRUE       = %w[true yes y 1 on].freeze
      BOOL_FALSE      = %w[false no n 0 off].freeze
      RANGE_OPS_MONGO = { ">" => "$gt", ">=" => "$gte", "<" => "$lt", "<=" => "$lte" }.freeze

      module_function

      def to_mongo(key, op, value)
        case key
        when "severity"   then exact_ci("finding.severity", value)
        when "status"     then exact_ci("report.status", value)
        when "tool"       then exact_ci("metadata.tool", value)
        when "type"       then exact_ci("finding.type", value)
        when "cwe"        then exact_ci("finding.cwe", value)
        when "ip"         then exact_ci("target.ip", value)
        when "port"       then exact_ci("target.port", value)
        when "method"     then exact_ci("target.method", value)
        when "confidence" then exact_ci("poc.confidence", value)
        when "tag"        then exact_ci("finding.tags", value)
        when "program"    then regex_field("metadata.program", value)
        when "asset"      then regex_field("metadata.asset", value)
        when "name"       then regex_field("finding.name", value)
        when "host"       then regex_field("target.host", value)
        when "url"        then regex_field("target.url", value)
        when "submitted"  then bool_clause("report.submitted", value)
        when "date"       then range_mongo("metadata.date", op, value, default_op: ">=")
        end
      end

      def evaluate(vuln, key, op, value)
        case key
        when "severity"   then eq_ci?(vuln.finding["severity"], value)
        when "status"     then eq_ci?(vuln.report["status"], value)
        when "tool"       then eq_ci?(vuln.metadata["tool"], value)
        when "type"       then eq_ci?(vuln.finding["type"], value)
        when "cwe"        then eq_ci?(vuln.finding["cwe"], value)
        when "ip"         then eq_ci?(vuln.target["ip"], value)
        when "port"       then eq_ci?(vuln.target["port"], value)
        when "method"     then eq_ci?(vuln.target["method"], value)
        when "confidence" then eq_ci?(vuln.poc["confidence"], value)
        when "tag"        then list_member_ci?(vuln.finding["tags"], value)
        when "program"    then substr_ci?(vuln.metadata["program"], value)
        when "asset"      then substr_ci?(vuln.metadata["asset"], value)
        when "name"       then substr_ci?(vuln.finding["name"], value)
        when "host"       then substr_ci?(vuln.target["host"], value)
        when "url"        then substr_ci?(vuln.target["url"], value)
        when "submitted"  then bool_eval(value, truthy?(vuln.report["submitted"]))
        when "date"       then range_eval(vuln.metadata["date"], op, value, ">=")
        else false
        end
      end

      # ---- mongo builders --------------------------------------------------

      # Case-insensitive exact match via an anchored regex, so parity with the
      # Ruby `casecmp?` path holds regardless of stored casing. On an array
      # field (tags) Mongo matches if ANY element matches.
      def exact_ci(field, value)
        return nil if value.to_s.empty?
        { field => { "$regex" => "\\A#{Regexp.escape(value.to_s.downcase)}\\z", "$options" => "i" } }
      end

      def regex_field(field, value)
        return nil if value.to_s.empty?
        { field => { "$regex" => Regexp.escape(value), "$options" => "i" } }
      end

      def bool_clause(field, value)
        v = value.to_s.downcase
        return { field => true }  if BOOL_TRUE.include?(v)
        return { field => false } if BOOL_FALSE.include?(v)
        nil
      end

      def range_mongo(field, op, value, default_op:)
        return nil if value.to_s.empty?
        mongo_op = RANGE_OPS_MONGO[op.presence || default_op]
        return nil unless mongo_op
        { field => { mongo_op => value.to_s } }
      end

      # ---- ruby evaluators -------------------------------------------------

      def eq_ci?(actual, value)
        return false if value.to_s.empty?
        actual.to_s.casecmp?(value.to_s)
      end

      def substr_ci?(actual, value)
        n = value.to_s.downcase
        return false if n.empty?
        actual.to_s.downcase.include?(n)
      end

      def list_member_ci?(list, value)
        Array(list).any? { |x| x.to_s.casecmp?(value.to_s) }
      end

      def bool_eval(value, actual)
        v = value.to_s.downcase
        return actual == true  if BOOL_TRUE.include?(v)
        return actual == false if BOOL_FALSE.include?(v)
        false
      end

      def range_eval(actual, op, value, default_op)
        return false if value.to_s.empty? || actual.to_s.empty?
        case op.presence || default_op
        when ">"  then actual.to_s >  value.to_s
        when ">=" then actual.to_s >= value.to_s
        when "<"  then actual.to_s <  value.to_s
        when "<=" then actual.to_s <= value.to_s
        else false
        end
      end

      def truthy?(value)
        BOOL_TRUE.include?(value.to_s.downcase) || value == true
      end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/services/vulnerabilities/dork_expression_test.rb`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git -c user.name="Claude" -c user.email="noreply@anthropic.com" add web/app/services/vulnerabilities/dork_expression.rb web/test/services/vulnerabilities/dork_expression_test.rb
git -c user.name="Claude" -c user.email="noreply@anthropic.com" commit -m "Add Vulnerabilities::DorkExpression AST and per-key Mongo/Ruby mapper."
```

---

### Task 2: `Vulnerabilities::SearchParser`

Parses the search bar into leftover free text plus a `DorkExpression` AST. Direct port of scope's recursive-descent parser; only the `KEYS` whitelist changes.

**Files:**
- Create: `web/app/services/vulnerabilities/search_parser.rb`
- Test: `web/test/services/vulnerabilities/search_parser_test.rb`

**Interfaces:**
- Consumes: `Vulnerabilities::DorkExpression::{Term,And,Or}` (Task 1).
- Produces: `Vulnerabilities::SearchParser.call(query) → Result(free_text:, expression:)` where `expression` is a `DorkExpression` node or `nil`.

- [ ] **Step 1: Write the failing test**

```ruby
# web/test/services/vulnerabilities/search_parser_test.rb
require "test_helper"

class Vulnerabilities::SearchParserTest < ActiveSupport::TestCase
  SP = Vulnerabilities::SearchParser
  DE = Vulnerabilities::DorkExpression

  test "plain words are free text with no expression" do
    r = SP.call("header fuzzer")
    assert_equal "header fuzzer", r.free_text
    assert_nil r.expression
  end

  test "a single dork becomes a Term and leaves free text behind" do
    r = SP.call("header severity:high")
    assert_equal "header", r.free_text
    assert_instance_of DE::Term, r.expression
    assert_equal ["severity", "high"], [r.expression.key, r.expression.value]
  end

  test "range operator is captured" do
    r = SP.call("date:>=2026-06-01")
    assert_equal ">=", r.expression.op
    assert_equal "2026-06-01", r.expression.value
  end

  test "AND binds tighter than OR" do
    r = SP.call("severity:high AND tool:nuclei OR tool:nikto")
    assert_instance_of DE::Or, r.expression
    assert_instance_of DE::And, r.expression.children.first
  end

  test "adjacent terms imply AND" do
    r = SP.call("severity:high tool:nuclei")
    assert_instance_of DE::And, r.expression
    assert_equal 2, r.expression.children.size
  end

  test "quoted values keep spaces" do
    r = SP.call(%(program:"Mirakl Helpdesk"))
    assert_equal "Mirakl Helpdesk", r.expression.value
  end

  test "unknown keys stay free text" do
    r = SP.call("foo:bar severity:low")
    assert_includes r.free_text, "foo:bar"
    assert_instance_of DE::Term, r.expression
  end

  test "prose with or is not parsed as an operator" do
    r = SP.call("cats or dogs")
    assert_equal "cats or dogs", r.free_text
    assert_nil r.expression
  end

  test "empty input yields empty free text and nil expression" do
    r = SP.call("")
    assert_equal "", r.free_text
    assert_nil r.expression
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/vulnerabilities/search_parser_test.rb`
Expected: FAIL — `uninitialized constant Vulnerabilities::SearchParser`.

- [ ] **Step 3: Write the implementation**

```ruby
# web/app/services/vulnerabilities/search_parser.rb
require "strscan"

module Vulnerabilities
  # Parses the search bar into:
  #   - `free_text`  — leftover plain words, fed into the broad :q search
  #   - `expression` — a DorkExpression AST (Term/And/Or) or nil
  #
  # Grammar (case-insensitive AND/OR/operators):
  #   expr     := or_expr
  #   or_expr  := and_expr (OR and_expr)*
  #   and_expr := primary (AND? primary)*           # adjacent terms imply AND
  #   primary  := '(' expr ')' | term
  #   term     := IDENT ':' [OP] (STRING | BAREWORD)
  #
  # AND binds tighter than OR. AND/OR words are only operators when both their
  # neighbors look like operands; otherwise they fall back to free text so
  # phrases like "cats or dogs" don't break.
  class SearchParser
    Result = Struct.new(:free_text, :expression, keyword_init: true)

    # Keys recognized as dorks; anything else is treated as free text. Keep in
    # sync with DorkExpression::Mapper.
    KEYS = %w[
      severity status tool type program asset name cwe tag
      host url ip port method submitted confidence date
    ].freeze

    OPERAND_TYPES = %i[term lparen rparen].freeze

    def self.call(query) = new(query).call

    def initialize(query)
      @query = query.to_s
    end

    def call
      raw = tokenize(@query)
      cooked = demote_orphan_operators(raw)
      free_text = cooked.select { |t| t[0] == :text }.map { |t| t[1] }.join(" ").strip
      @tokens = cooked.reject { |t| t[0] == :text }
      @pos = 0
      Result.new(free_text: free_text, expression: parse_or)
    end

    private

    def tokenize(str)
      s = StringScanner.new(str)
      tokens = []
      until s.eos?
        if s.scan(/\s+/)
          next
        elsif s.scan(/\(/)
          tokens << [:lparen]
        elsif s.scan(/\)/)
          tokens << [:rparen]
        elsif s.scan(/(?:&&|\band\b)/i)
          tokens << [:and]
        elsif s.scan(/(?:\|\||\bor\b)/i)
          tokens << [:or]
        elsif s.scan(/(\w+):(>=|<=|>|<)?(?:"([^"]+)"|([^\s()]+))/)
          key = s[1].downcase
          op  = s[2]
          val = s[3] || s[4]
          tokens << (KEYS.include?(key) ? [:term, key, op, val] : [:text, s.matched])
        else
          word = s.scan(/\S+/)
          tokens << [:text, word] if word
        end
      end
      tokens
    end

    def demote_orphan_operators(tokens)
      tokens.each_with_index.map do |tok, i|
        next tok unless %i[and or].include?(tok[0])
        prev_t = i > 0 ? tokens[i - 1] : nil
        next_t = tokens[i + 1]
        operand_like?(prev_t) && operand_like?(next_t) ? tok : [:text, tok[0].to_s]
      end
    end

    def operand_like?(t) = t && OPERAND_TYPES.include?(t[0])

    def peek = @tokens[@pos]
    def at?(type) = peek && peek[0] == type
    def consume   = @tokens[@pos].tap { @pos += 1 }

    def parse_or
      left = parse_and
      return nil unless left
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
      return nil if children.empty?
      return children.first if children.size == 1
      DorkExpression::And.new(children: children)
    end

    def parse_primary
      return nil unless peek
      if at?(:lparen)
        consume
        expr = parse_or
        consume if at?(:rparen)
        expr
      elsif at?(:term)
        _, key, op, val = consume
        DorkExpression::Term.new(key: key, op: op, value: val)
      end
    end

    def combine(klass, left, right)
      left_kids  = left.is_a?(klass)  ? left.children  : [left]
      right_kids = right.is_a?(klass) ? right.children : [right]
      klass.new(children: left_kids + right_kids)
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/services/vulnerabilities/search_parser_test.rb`
Expected: PASS (9 tests).

- [ ] **Step 5: Commit**

```bash
git -c user.name="Claude" -c user.email="noreply@anthropic.com" add web/app/services/vulnerabilities/search_parser.rb web/test/services/vulnerabilities/search_parser_test.rb
git -c user.name="Claude" -c user.email="noreply@anthropic.com" commit -m "Add Vulnerabilities::SearchParser translating the search bar into a dork AST plus free text."
```

---

### Task 3: `Vulnerabilities::Sort`

Sort keys → Mongo sort spec, with a severity rank and a stable tiebreaker.

**Files:**
- Create: `web/app/services/vulnerabilities/sort.rb`
- Test: `web/test/services/vulnerabilities/sort_test.rb`

**Interfaces:**
- Produces:
  - `Vulnerabilities::Sort::OPTIONS → Hash{String=>String}` (key → human label) for the view select.
  - `Vulnerabilities::Sort::DEFAULT_KEY → "date"`.
  - `Vulnerabilities::Sort.resolve_dir(key, dir) → "asc"|"desc"`.
  - `Vulnerabilities::Sort.mongo_doc(key, dir) → Hash` (Mongo sort spec; severity uses an added `$addFields` rank handled by `Query`, so here it maps to the raw field with a documented rank note).
  - `Vulnerabilities::Sort.comparator(key, dir) → Proc` for the in-memory fallback: `->(a, b)` over two `Vulnerability` instances.

- [ ] **Step 1: Write the failing test**

```ruby
# web/test/services/vulnerabilities/sort_test.rb
require "test_helper"

class Vulnerabilities::SortTest < ActiveSupport::TestCase
  S = Vulnerabilities::Sort

  def vuln(sev, date, name = "x")
    Vulnerability.new("finding" => { "severity" => sev, "name" => name }, "metadata" => { "date" => date }, "id" => name)
  end

  test "default key and direction" do
    assert_equal "date", S::DEFAULT_KEY
    assert_equal "desc", S.resolve_dir("date", nil)
  end

  test "unknown direction falls back to the key default" do
    assert_equal "asc", S.resolve_dir("name", "sideways")
    assert_equal "asc", S.resolve_dir("name", nil)
  end

  test "mongo_doc maps date desc with a stable tiebreaker" do
    assert_equal({ "metadata.date" => -1, "_id" => -1 }, S.mongo_doc("date", "desc"))
  end

  test "severity comparator orders critical before info regardless of direction default" do
    list = [vuln("info", "2026-01-01", "a"), vuln("critical", "2026-01-01", "b")]
    sorted = list.sort(&S.comparator("severity", S.resolve_dir("severity", nil)))
    assert_equal ["b", "a"], sorted.map(&:id)
  end

  test "date comparator desc puts newer first" do
    list = [vuln("low", "2026-01-01", "old"), vuln("low", "2026-06-01", "new")]
    sorted = list.sort(&S.comparator("date", "desc"))
    assert_equal ["new", "old"], sorted.map(&:id)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/vulnerabilities/sort_test.rb`
Expected: FAIL — `uninitialized constant Vulnerabilities::Sort`.

- [ ] **Step 3: Write the implementation**

```ruby
# web/app/services/vulnerabilities/sort.rb
module Vulnerabilities
  # Sort options for the findings list. Each key maps to a Mongo field (for the
  # indexed path) and an in-memory comparator (for the fallback). Severity sorts
  # by a fixed rank, not alphabetically.
  module Sort
    module_function

    DEFAULT_KEY = "date"

    OPTIONS = {
      "date"     => "Date",
      "severity" => "Severity",
      "status"   => "Status",
      "program"  => "Program",
      "name"     => "Name"
    }.freeze

    # Default direction per key: newest dates and highest severity first; every
    # other key ascends. Default set before freezing (can't mutate a frozen Hash).
    DEFAULT_DIR = Hash.new("asc").merge("date" => "desc", "severity" => "desc").freeze

    FIELDS = {
      "date"     => "metadata.date",
      "status"   => "report.status",
      "program"  => "metadata.program",
      "name"     => "finding.name"
    }.freeze

    # High number = more severe, so "desc" puts critical on top.
    SEVERITY_RANK = { "critical" => 5, "high" => 4, "medium" => 3, "low" => 2, "info" => 1 }.freeze

    def resolve_dir(key, dir)
      d = dir.to_s.downcase
      return d if %w[asc desc].include?(d)
      DEFAULT_DIR[key.to_s]
    end

    def key?(key) = OPTIONS.key?(key.to_s)

    def resolve_key(key) = key?(key) ? key.to_s : DEFAULT_KEY

    # Mongo sort spec. Severity is handled by Query via an added rank field
    # ("_sevrank"); every other key maps to its stored field. A stable "_id"
    # tiebreaker (same direction) keeps paged windows from shuffling ties.
    def mongo_doc(key, dir)
      key = resolve_key(key)
      sign = resolve_dir(key, dir) == "asc" ? 1 : -1
      field = key == "severity" ? "_sevrank" : FIELDS[key]
      { field => sign, "_id" => sign }
    end

    # Comparator over two Vulnerability instances for the in-memory fallback.
    def comparator(key, dir)
      key = resolve_key(key)
      sign = resolve_dir(key, dir) == "asc" ? 1 : -1
      lambda do |a, b|
        (sort_value(a, key) <=> sort_value(b, key)) * sign
      end
    end

    def sort_value(vuln, key)
      case key
      when "severity" then SEVERITY_RANK.fetch(vuln.finding["severity"].to_s.downcase, 0)
      when "date"     then vuln.metadata["date"].to_s
      when "status"   then vuln.report["status"].to_s
      when "program"  then vuln.metadata["program"].to_s
      when "name"     then vuln.finding["name"].to_s
      else vuln.metadata["date"].to_s
      end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/services/vulnerabilities/sort_test.rb`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git -c user.name="Claude" -c user.email="noreply@anthropic.com" add web/app/services/vulnerabilities/sort.rb web/test/services/vulnerabilities/sort_test.rb
git -c user.name="Claude" -c user.email="noreply@anthropic.com" commit -m "Add Vulnerabilities::Sort with severity-rank ordering and an in-memory comparator."
```

---

### Task 4: `Vulnerabilities::Filter` (in-memory)

Applies the facet params + dork expression to a Ruby list of `Vulnerability` instances. Used as the fallback path and as a clean unit-test seam. Also computes facet counts in Ruby.

**Files:**
- Create: `web/app/services/vulnerabilities/filter.rb`
- Test: `web/test/services/vulnerabilities/filter_test.rb`

**Interfaces:**
- Consumes: `Vulnerabilities::DorkExpression` node (via `params[:dork_expression]`), `Vulnerability` PORO.
- Produces:
  - `Vulnerabilities::Filter.call(vulns, params) → Array<Vulnerability>` (filtered, unsorted).
  - `Vulnerabilities::Filter.facets(vulns, params) → Hash{String=>Hash{String=>Integer}}` — per-dimension counts computed with all *other* active facet filters applied (not the dimension's own), keys = `severity status tool type program`.
- `params` is a Hash with indifferent access carrying: `:q` (free text), `:dork_expression`, and array facets `:severity, :status, :tool, :type, :program`, plus `:date_from`, `:date_to`.

- [ ] **Step 1: Write the failing test**

```ruby
# web/test/services/vulnerabilities/filter_test.rb
require "test_helper"

class Vulnerabilities::FilterTest < ActiveSupport::TestCase
  F = Vulnerabilities::Filter

  def v(sev:, status: "new", tool: "nuclei", type: "http", program: "Acme", name: "n", host: "h.example.com", date: "2026-06-01", tags: [])
    Vulnerability.new(
      "finding"  => { "severity" => sev, "type" => type, "name" => name, "tags" => tags },
      "report"   => { "status" => status },
      "metadata" => { "tool" => tool, "program" => program, "date" => date },
      "target"   => { "host" => host }, "id" => "#{sev}-#{name}"
    )
  end

  def setup
    @all = [
      v(sev: "critical", tool: "nuclei", program: "Acme"),
      v(sev: "high",     tool: "nikto",  program: "Acme"),
      v(sev: "low",      tool: "nuclei", program: "Beta", name: "sqli")
    ]
  end

  test "severity facet param keeps only matching rows" do
    out = F.call(@all, { severity: ["critical"] }.with_indifferent_access)
    assert_equal ["critical-n"], out.map(&:id)
  end

  test "multi-value facet is an OR within the dimension" do
    out = F.call(@all, { severity: ["critical", "high"] }.with_indifferent_access)
    assert_equal 2, out.size
  end

  test "free text matches name or host" do
    out = F.call(@all, { q: "sqli" }.with_indifferent_access)
    assert_equal ["low-sqli"], out.map(&:id)
  end

  test "dork expression is applied" do
    expr = Vulnerabilities::SearchParser.call("tool:nuclei").expression
    out = F.call(@all, { dork_expression: expr }.with_indifferent_access)
    assert_equal ["critical-n", "low-sqli"], out.map(&:id)
  end

  test "date range is inclusive" do
    old = v(sev: "low", date: "2026-01-01", name: "old")
    out = F.call(@all + [old], { date_from: "2026-05-01" }.with_indifferent_access)
    assert_not_includes out.map(&:id), "low-old"
  end

  test "facets count with other filters applied but not their own dimension" do
    facets = F.facets(@all, { severity: ["critical"] }.with_indifferent_access)
    # severity dimension ignores its own filter -> all three severities counted
    assert_equal({ "critical" => 1, "high" => 1, "low" => 1 }, facets["severity"])
    # tool dimension respects the severity filter -> only nuclei/critical remains
    assert_equal({ "nuclei" => 1 }, facets["tool"])
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/vulnerabilities/filter_test.rb`
Expected: FAIL — `uninitialized constant Vulnerabilities::Filter`.

- [ ] **Step 3: Write the implementation**

```ruby
# web/app/services/vulnerabilities/filter.rb
module Vulnerabilities
  # In-memory equivalent of Query's Mongo match, over a Ruby list of
  # Vulnerability instances. Used when Mongo is empty/unreachable and as a
  # unit-test seam. Facet field paths are the single source of truth shared
  # with Query via FACET_FIELDS.
  module Filter
    module_function

    # dimension name -> [section, key] reader on Vulnerability.
    FACET_FIELDS = {
      "severity" => %w[finding severity],
      "status"   => %w[report status],
      "tool"     => %w[metadata tool],
      "type"     => %w[finding type],
      "program"  => %w[metadata program]
    }.freeze

    SEARCH_READERS = [%w[finding name], %w[target host], %w[metadata program], %w[target url]].freeze

    def call(vulns, params)
      vulns.select { |v| keep?(v, params) }
    end

    # Per-dimension counts: each dimension counts the set filtered by every
    # OTHER active facet (and free text / dork / date), but NOT its own — so a
    # selected value still shows its siblings' availability.
    def facets(vulns, params)
      FACET_FIELDS.keys.each_with_object({}) do |dim, out|
        subset = vulns.select { |v| keep?(v, params, except: dim) }
        counts = Hash.new(0)
        section, key = FACET_FIELDS[dim]
        subset.each do |v|
          value = v.public_send(section)[key]
          next if value.to_s.empty?
          counts[value.to_s] += 1
        end
        out[dim] = counts
      end
    end

    def keep?(vuln, params, except: nil)
      return false unless matches_facets?(vuln, params, except)
      return false unless matches_date?(vuln, params)
      return false unless matches_search?(vuln, params)
      return false unless matches_dork?(vuln, params)
      true
    end

    def matches_facets?(vuln, params, except)
      FACET_FIELDS.each do |dim, (section, key)|
        next if dim == except
        values = Array(params[dim]).reject(&:blank?)
        next if values.empty?
        actual = vuln.public_send(section)[key].to_s
        return false unless values.any? { |val| val.casecmp?(actual) }
      end
      true
    end

    def matches_date?(vuln, params)
      date = vuln.metadata["date"].to_s
      from = params[:date_from].to_s
      to   = params[:date_to].to_s
      return false if from.present? && (date.empty? || date < from)
      return false if to.present?   && (date.empty? || date > to)
      true
    end

    def matches_search?(vuln, params)
      q = params[:q].to_s.strip.downcase
      return true if q.empty?
      SEARCH_READERS.any? do |section, key|
        vuln.public_send(section)[key].to_s.downcase.include?(q)
      end
    end

    def matches_dork?(vuln, params)
      expr = params[:dork_expression]
      return true unless expr
      expr.evaluate(vuln)
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/services/vulnerabilities/filter_test.rb`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git -c user.name="Claude" -c user.email="noreply@anthropic.com" add web/app/services/vulnerabilities/filter.rb web/test/services/vulnerabilities/filter_test.rb
git -c user.name="Claude" -c user.email="noreply@anthropic.com" commit -m "Add Vulnerabilities::Filter for the in-memory fallback with other-filters facet counts."
```

---

### Task 5: `Vulnerabilities::Query`

Page orchestrator. Builds the Mongo match doc from facet params + dork AST, runs count + a `$facet` counts aggregation + the paged/sorted window, and falls back to `Filter` + `Sort` when Mongo is empty/unreachable.

**Files:**
- Create: `web/app/services/vulnerabilities/query.rb`
- Modify: `web/app/services/vulnerabilities/mongo_source.rb` — add facet-field indexes (append to `INDEXES`).
- Test: `web/test/services/vulnerabilities/query_test.rb`

**Interfaces:**
- Consumes: `MongoSource.collection`, `HunterMongo.ensure_indexes_once!`, `DorkExpression` node, `Filter`, `Sort`.
- Produces: `Vulnerabilities::Query.call(params) → Result` where
  `Result = Struct.new(:findings, :total, :facets, :page, :per_page, :has_next, :sort_key, :sort_dir, keyword_init: true)`, `findings` is `Array<Vulnerability>`, `facets` is `Hash{String=>Hash{String=>Integer}}`.
- `params` (indifferent access): `:q`, `:dork_expression`, `:severity[]`, `:status[]`, `:tool[]`, `:type[]`, `:program[]`, `:date_from`, `:date_to`, `:sort`, `:dir`, `:page`.

- [ ] **Step 1: Add facet indexes to MongoSource**

In `web/app/services/vulnerabilities/mongo_source.rb`, extend `INDEXES` so the new facets are indexed:

```ruby
    INDEXES = [
      { key: { "metadata.program": 1 },  name: "metadata_program" },
      { key: { "finding.severity": 1 },  name: "finding_severity" },
      { key: { "report.status": 1 },     name: "report_status" },
      { key: { "metadata.tool": 1 },     name: "metadata_tool" },
      { key: { "finding.type": 1 },      name: "finding_type" },
      { key: { "metadata.date": -1 },    name: "metadata_date" }
    ].freeze
```

- [ ] **Step 2: Write the failing test**

```ruby
# web/test/services/vulnerabilities/query_test.rb
require "test_helper"

class Vulnerabilities::QueryTest < ActiveSupport::TestCase
  Q = Vulnerabilities::Query

  # --- match doc (pure, no Mongo) ---------------------------------------
  test "match doc combines facets, date range, free text and dork" do
    expr = Vulnerabilities::SearchParser.call("tool:nuclei").expression
    q = Q.new({ severity: ["critical", "high"], date_from: "2026-01-01",
                q: "login", dork_expression: expr }.with_indifferent_access)
    doc = q.send(:match_doc)
    assert_equal({ "$in" => ["critical", "high"] }, doc["finding.severity"])
    assert_equal({ "$gte" => "2026-01-01" }, doc["metadata.date"])
    assert doc["$and"].any? { |c| c["metadata.tool"] }, "dork clause present"
    assert doc["$or"].present?, "free-text $or present"
  end

  test "match doc for a dimension can exclude that dimension for facet counts" do
    q = Q.new({ severity: ["critical"], tool: ["nuclei"] }.with_indifferent_access)
    doc = q.send(:match_doc, except: "severity")
    assert_nil doc["finding.severity"], "own dimension excluded"
    assert_equal({ "$in" => ["nuclei"] }, doc["metadata.tool"])
  end

  # --- fallback path (no live Mongo) ------------------------------------
  test "falls back to in-memory Filter + Sort when mongo is unusable" do
    vulns = [
      Vulnerability.new("finding" => { "severity" => "low", "name" => "a" }, "metadata" => { "date" => "2026-01-01" }, "id" => "a"),
      Vulnerability.new("finding" => { "severity" => "critical", "name" => "b" }, "metadata" => { "date" => "2026-06-01" }, "id" => "b")
    ]
    result = nil
    # mongo_usable? / fallback_source are private INSTANCE methods, so stub them
    # on an instance (stub_methods redefines singleton methods on its target).
    q = Q.new({ sort: "severity" }.with_indifferent_access)
    stub_methods(q, mongo_usable?: false, fallback_source: vulns) do
      result = q.call
    end
    assert_equal ["b", "a"], result.findings.map(&:id)
    assert_equal 2, result.total
    assert_equal 1, result.facets["severity"]["critical"]
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bin/rails test test/services/vulnerabilities/query_test.rb`
Expected: FAIL — `uninitialized constant Vulnerabilities::Query`.

- [ ] **Step 4: Write the implementation**

```ruby
# web/app/services/vulnerabilities/query.rb
module Vulnerabilities
  # Single entry point for the vulnerabilities index. Translates filter params
  # into a Mongo query (match + $facet counts + sorted page) and returns only
  # the matching rows. Falls back to the in-memory Filter+Sort pipeline when the
  # collection is empty or Mongo is unreachable, so the page always renders.
  class Query
    Result = Struct.new(
      :findings, :total, :facets, :page, :per_page, :has_next, :sort_key, :sort_dir,
      keyword_init: true
    )

    DEFAULT_PER_PAGE = 50
    MAX_PER_PAGE     = 100

    # Facet dimension -> Mongo field. Shared shape with Filter::FACET_FIELDS.
    FACET_FIELDS = {
      "severity" => "finding.severity",
      "status"   => "report.status",
      "tool"     => "metadata.tool",
      "type"     => "finding.type",
      "program"  => "metadata.program"
    }.freeze

    SEARCH_FIELDS = %w[finding.name target.host metadata.program target.url].freeze

    def self.call(params) = new(params).call

    def initialize(params)
      @params = params
    end

    def call
      if mongo_usable?
        MongoSource.ensure_indexes!
        query_mongo
      else
        query_fallback
      end
    rescue Mongo::Error => e
      Rails.logger.warn("Vulnerabilities::Query failed, falling back (#{e.class}: #{e.message})")
      query_fallback
    end

    private

    def mongo_usable?
      return false unless HunterMongo.healthy?
      collection.estimated_document_count.positive?
    rescue Mongo::Error
      false
    end

    def collection = MongoSource.collection

    # --- mongo path -------------------------------------------------------

    def query_mongo
      match = match_doc
      total = collection.count_documents(match)
      offset = (page - 1) * per_page

      findings = fetch_page(match, offset).map { |doc| Vulnerability.new(normalize(doc)) }

      Result.new(
        findings: findings,
        total:    total,
        facets:   facet_counts_mongo,
        page:     page,
        per_page: per_page,
        has_next: (offset + findings.size) < total,
        sort_key: sort_key,
        sort_dir: sort_dir
      )
    end

    def fetch_page(match, offset)
      pipeline = [{ "$match" => match }]
      # Severity sort needs a numeric rank the documents don't carry.
      if sort_key == "severity"
        branches = Sort::SEVERITY_RANK.map { |sev, rank| { "case" => { "$eq" => ["$finding.severity", sev] }, "then" => rank } }
        pipeline << { "$addFields" => { "_sevrank" => { "$switch" => { "branches" => branches, "default" => 0 } } } }
      end
      pipeline += [
        { "$sort" => Sort.mongo_doc(sort_key, sort_dir) },
        { "$skip" => offset },
        { "$limit" => per_page }
      ]
      collection.aggregate(pipeline).to_a
    end

    # One aggregation, one sub-pipeline per dimension, each matching on all
    # OTHER active filters (match_doc(except: dim)) then grouping by the field.
    def facet_counts_mongo
      facets = FACET_FIELDS.each_with_object({}) do |(dim, field), spec|
        spec[dim] = [
          { "$match" => match_doc(except: dim) },
          { "$group" => { "_id" => "$#{field}", "n" => { "$sum" => 1 } } }
        ]
      end
      raw = collection.aggregate([{ "$facet" => facets }]).first || {}
      FACET_FIELDS.keys.each_with_object({}) do |dim, out|
        counts = {}
        Array(raw[dim]).each do |row|
          id = row["_id"]
          next if id.to_s.empty?
          counts[id.to_s] = row["n"]
        end
        out[dim] = counts
      end
    end

    # match_doc(except:) omits one dimension's own facet clause so its counts
    # reflect availability given the OTHER filters.
    def match_doc(except: nil)
      doc = {}
      add_search(doc)
      add_dork(doc)
      FACET_FIELDS.each do |dim, field|
        next if dim == except
        values = Array(@params[dim]).reject(&:blank?)
        doc[field] = { "$in" => values } unless values.empty?
      end
      add_date_range(doc)
      doc
    end

    def add_search(doc)
      q = @params[:q].to_s.strip
      return if q.empty?
      re = Regexp.escape(q)
      doc["$or"] = SEARCH_FIELDS.map { |f| { f => { "$regex" => re, "$options" => "i" } } }
    end

    def add_dork(doc)
      expr = @params[:dork_expression]
      return unless expr
      clause = expr.to_mongo
      return unless clause
      doc["$and"] = (doc["$and"] || []) + [clause]
    end

    def add_date_range(doc)
      from = @params[:date_from].to_s
      to   = @params[:date_to].to_s
      return if from.empty? && to.empty?
      range = {}
      range["$gte"] = from unless from.empty?
      range["$lte"] = to   unless to.empty?
      doc["metadata.date"] = range
    end

    # --- fallback path ----------------------------------------------------

    def query_fallback
      all = fallback_source
      filtered = Filter.call(all, @params)
      sorted = filtered.sort(&Sort.comparator(sort_key, sort_dir))
      offset = (page - 1) * per_page
      window = sorted[offset, per_page] || []

      Result.new(
        findings: window,
        total:    sorted.size,
        facets:   Filter.facets(all, @params),
        page:     page,
        per_page: per_page,
        has_next: (offset + window.size) < sorted.size,
        sort_key: sort_key,
        sort_dir: sort_dir
      )
    end

    # Seam: the set the fallback filters over. Empty by default (dev path with
    # no Mongo); overridable in tests. Reads swallow Mongo errors to [].
    def fallback_source
      collection.find.limit(MAX_PER_PAGE * 5).map { |doc| Vulnerability.new(normalize(doc)) }
    rescue Mongo::Error
      []
    end

    # --- shared helpers ---------------------------------------------------

    def sort_key = Sort.resolve_key(@params[:sort])
    def sort_dir = Sort.resolve_dir(sort_key, @params[:dir])

    def page
      @page ||= [@params[:page].to_i, 1].max
    end

    def per_page = DEFAULT_PER_PAGE

    def normalize(doc)
      hash = doc.to_h.transform_keys(&:to_s)
      oid = hash.delete("_id")
      hash["id"] = oid.to_s if oid
      hash
    end
  end
end
```

Also add a thin `MongoSource.ensure_indexes!` wrapper the Query calls (keeps the collection name + INDEXES in one place). In `web/app/services/vulnerabilities/mongo_source.rb`, add:

```ruby
    # Bootstrap this module's indexes (idempotent, once per process).
    def ensure_indexes!
      HunterMongo.ensure_indexes_once!(COLLECTION, INDEXES)
    end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bin/rails test test/services/vulnerabilities/query_test.rb`
Expected: PASS (3 tests). The fallback test stubs `mongo_usable?` and `fallback_source`; the match-doc tests are pure.

- [ ] **Step 6: Run the whole service suite**

Run: `bin/rails test test/services/vulnerabilities/`
Expected: PASS (all of Tasks 1–5).

- [ ] **Step 7: Commit**

```bash
git -c user.name="Claude" -c user.email="noreply@anthropic.com" add web/app/services/vulnerabilities/query.rb web/app/services/vulnerabilities/mongo_source.rb web/test/services/vulnerabilities/query_test.rb
git -c user.name="Claude" -c user.email="noreply@anthropic.com" commit -m "Add Vulnerabilities::Query with Mongo faceted search, sorting, and in-memory fallback."
```

---

### Task 6: Controller wiring + chip/facet helpers

Switch `OverviewController` to `Query`, parse the dork bar, permit the new params, and add view helpers for facet options and active-filter chips.

**Files:**
- Modify: `web/app/controllers/vulnerabilities/overview_controller.rb`
- Modify: `web/app/helpers/vulnerabilities_helper.rb`
- Test: `web/test/integration/vulnerabilities/overview_test.rb` (extend existing)

**Interfaces:**
- Consumes: `Vulnerabilities::{SearchParser,Query,Sort}` (Tasks 2/5/3).
- Produces (assigned for the views): `@result` (`Query::Result`), `@filter_params` (permitted params hash), `@sort_key`, `@sort_dir`.
- Helper methods: `vuln_facet_label(dim, value)`, `vuln_active_chips(params) → Array<{label:, remove_params:}>`, `vuln_chip_params_without(params, dim, value=nil) → Hash`.

- [ ] **Step 1: Write the failing test**

```ruby
# add to web/test/integration/vulnerabilities/overview_test.rb
  test "applies a dork query and multi-select facets through Query" do
    captured = nil
    fake = Vulnerabilities::Query::Result.new(
      findings: [], total: 0, facets: { "severity" => { "high" => 3 } },
      page: 1, per_page: 50, has_next: false, sort_key: "date", sort_dir: "desc"
    )
    stub_methods(Vulnerabilities::Query, call: ->(params) { captured = params; fake }) do
      get vulnerabilities_root_path, params: { q: "severity:high login", severity: ["high", "critical"], sort: "date" }
    end
    assert_response :success
    assert_equal ["high", "critical"], captured[:severity]
    assert_equal "login", captured[:q], "dork stripped, free text kept"
    assert captured[:dork_expression], "parsed expression forwarded"
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/integration/vulnerabilities/overview_test.rb`
Expected: FAIL — `Query` receives raw params / no `dork_expression` (current controller uses `MongoSource.all`).

- [ ] **Step 3: Rewrite the controller**

```ruby
# web/app/controllers/vulnerabilities/overview_controller.rb
module Vulnerabilities
  # The vulnerabilities dashboard: summary stat cards on top, a dork-searchable /
  # faceted / sorted / paginated findings list below. Renders HTML by calling the
  # module's services directly (the JSON API is a separate surface).
  class OverviewController < BaseController
    def index
      @filter_params = filter_params
      parsed = Vulnerabilities::SearchParser.call(@filter_params[:q])

      query_params = @filter_params.merge(q: parsed.free_text, dork_expression: parsed.expression)
      @result   = Vulnerabilities::Query.call(query_params)
      @findings = @result.findings
      @sort_key = @result.sort_key
      @sort_dir = @result.sort_dir
      @stats    = Stats.summary
    end

    private

    # Indifferent-access hash so downstream services can use symbol keys.
    def filter_params
      params.permit(
        :q, :sort, :dir, :page, :date_from, :date_to,
        severity: [], status: [], tool: [], type: [], program: []
      ).to_h.with_indifferent_access
    end
  end
end
```

- [ ] **Step 4: Add the helper methods**

Append to `web/app/helpers/vulnerabilities_helper.rb` (inside the module):

```ruby
  # Facet dimensions that render as multi-select checkbox groups, in order.
  FACET_DIMENSIONS = %w[severity status tool type program].freeze

  # Human label for a facet value (severity/status humanize; others verbatim).
  def vuln_facet_label(dim, value)
    %w[severity status].include?(dim) ? value.to_s.humanize : value.to_s
  end

  # Active-filter chips: one per free-text query, per selected facet value, and
  # per date bound. Each carries the param hash to link to when removed.
  def vuln_active_chips(params)
    chips = []
    chips << { label: %(search: "#{params[:q]}"), remove_params: vuln_chip_params_without(params, :q) } if params[:q].present?
    FACET_DIMENSIONS.each do |dim|
      Array(params[dim]).reject(&:blank?).each do |value|
        chips << { label: "#{dim}: #{vuln_facet_label(dim, value)}", remove_params: vuln_chip_params_without(params, dim, value) }
      end
    end
    { date_from: "from", date_to: "to" }.each do |key, word|
      chips << { label: "#{word}: #{params[key]}", remove_params: vuln_chip_params_without(params, key) } if params[key].present?
    end
    chips
  end

  # Copy of the current filter params with one value removed: the whole key for
  # scalars, or a single element for a multi-select dimension. Page is reset.
  def vuln_chip_params_without(params, key, value = nil)
    key = key.to_s
    copy = params.to_unsafe_h.deep_dup.with_indifferent_access
    copy.delete(:page)
    if value && copy[key].is_a?(Array)
      copy[key] = copy[key] - [value]
      copy.delete(key) if copy[key].empty?
    else
      copy.delete(key)
    end
    copy
  end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bin/rails test test/integration/vulnerabilities/overview_test.rb`
Expected: PASS. (Views still render the old `_filters`; the sidebar/chips come in Task 7. If a view references a not-yet-added partial, temporarily this task only needs the controller test green — the existing `index.html.erb` still renders.)

- [ ] **Step 6: Commit**

```bash
git -c user.name="Claude" -c user.email="noreply@anthropic.com" add web/app/controllers/vulnerabilities/overview_controller.rb web/app/helpers/vulnerabilities_helper.rb web/test/integration/vulnerabilities/overview_test.rb
git -c user.name="Claude" -c user.email="noreply@anthropic.com" commit -m "Wire the vulnerabilities overview to Query with dork parsing and add facet/chip helpers."
```

---

### Task 7: Sidebar facets, active chips, sort control, two-column layout

Build the sidebar and chips views and restructure the overview into a facet sidebar + results column.

**Files:**
- Modify: `web/app/views/vulnerabilities/overview/index.html.erb`
- Modify: `web/app/views/vulnerabilities/overview/_filters.html.erb`
- Create: `web/app/views/vulnerabilities/overview/_facets.html.erb`
- Create: `web/app/views/vulnerabilities/overview/_active_chips.html.erb`
- Test: `web/test/integration/vulnerabilities/overview_test.rb` (extend)

**Interfaces:**
- Consumes: `@result` (`Query::Result` — `#facets`, `#findings`, `#total`, …), `@filter_params`, `@sort_key`, `@sort_dir`, and helpers `vuln_active_chips`, `vuln_facet_label`, `VulnerabilitiesHelper::{SEVERITIES,STATUSES,FACET_DIMENSIONS}`, `Vulnerabilities::Sort::OPTIONS`.

- [ ] **Step 1: Write the failing test**

```ruby
# add to web/test/integration/vulnerabilities/overview_test.rb
  test "renders facet sidebar with counts and active chips with remove links" do
    fake = Vulnerabilities::Query::Result.new(
      findings: [], total: 0,
      facets: { "severity" => { "critical" => 12, "high" => 40 }, "status" => {}, "tool" => { "nuclei" => 7 }, "type" => {}, "program" => {} },
      page: 1, per_page: 50, has_next: false, sort_key: "date", sort_dir: "desc"
    )
    stub_methods(Vulnerabilities::Query, call: ->(*) { fake }) do
      get vulnerabilities_root_path, params: { severity: ["critical"] }
    end
    assert_response :success
    assert_select "input[type=checkbox][name='severity[]'][value=critical][checked]"
    assert_select "aside", text: /critical/
    assert_select "aside", text: /12/
    # active chip for the selected severity with a remove link that drops it
    assert_select "a", text: /severity: Critical/i
    assert_select "select[name=sort]"
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/integration/vulnerabilities/overview_test.rb`
Expected: FAIL — no `aside`, no `severity[]` checkbox, no sort select yet.

- [ ] **Step 3: Rewrite `index.html.erb` (two-column shell)**

```erb
<%# web/app/views/vulnerabilities/overview/index.html.erb %>
<% content_for :title, "hunter — Vulnerabilities" %>
<% content_for :container, "mx-auto max-w-screen-2xl px-6 py-10" %>

<header class="flex items-center gap-3">
  <h1 class="text-2xl font-semibold text-zinc-900 dark:text-zinc-100">Vulnerabilities</h1>
  <span class="rounded border border-zinc-300 px-1.5 py-0.5 text-xs font-medium text-zinc-600 dark:border-zinc-700 dark:text-zinc-400">beta</span>
</header>
<p class="mt-1 text-sm text-zinc-500 dark:text-zinc-400">Findings across all programs.</p>

<%= render "vulnerabilities/overview/stat_cards", stats: @stats %>

<div class="mt-8 flex flex-col gap-6 lg:flex-row lg:items-start">
  <aside class="w-full shrink-0 lg:w-64">
    <%= render "vulnerabilities/overview/facets", result: @result, filter_params: @filter_params %>
  </aside>

  <div class="min-w-0 flex-1 overflow-hidden rounded-lg border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-[#111315]">
    <%= render "vulnerabilities/overview/filters", filter_params: @filter_params, sort_key: @sort_key, sort_dir: @sort_dir %>
    <%= render "vulnerabilities/overview/active_chips", filter_params: @filter_params %>
    <%= render "vulnerabilities/overview/findings_table", findings: @findings %>
    <%= render "shared/pagination", page: @result.page, limit: @result.per_page, total: @result.total %>
  </div>
</div>

<%# Detail drawer mounts here — findings rows swap their detail into this frame. %>
<%= turbo_frame_tag "vuln_panel" %>
```

- [ ] **Step 4: Rewrite `_filters.html.erb` (dork search + sort)**

```erb
<%# web/app/views/vulnerabilities/overview/_filters.html.erb %>
<%
  input_classes = "rounded-md border border-zinc-300 bg-white px-3 py-1.5 text-sm text-zinc-900 placeholder:text-zinc-400 focus:border-zinc-900 focus:outline-none dark:border-zinc-700 dark:bg-[#0b0d0e] dark:text-zinc-100 dark:focus:border-zinc-300"
%>
<%= form_with url: vulnerabilities_root_path, method: :get,
      data: { controller: "filter_form" },
      class: "flex flex-wrap items-center gap-3 border-b border-zinc-200 p-4 dark:border-zinc-800" do |f| %>
  <div class="min-w-48 flex-1">
    <%= f.search_field :q, value: filter_params[:q], placeholder: "Search — e.g. severity:high AND tool:nuclei",
          autocomplete: "off",
          data: { filter_form_target: "search", action: "input->filter_form#search" },
          class: "w-full #{input_classes}" %>
  </div>

  <%# Preserve active facet selections across a search/sort submit. %>
  <% VulnerabilitiesHelper::FACET_DIMENSIONS.each do |dim| %>
    <% Array(filter_params[dim]).reject(&:blank?).each do |value| %>
      <%= hidden_field_tag "#{dim}[]", value %>
    <% end %>
  <% end %>
  <% %i[date_from date_to].each do |k| %>
    <%= hidden_field_tag k, filter_params[k] if filter_params[k].present? %>
  <% end %>

  <label class="flex items-center gap-2 text-sm text-zinc-500 dark:text-zinc-400">
    Sort
    <%= f.select :sort,
          options_for_select(Vulnerabilities::Sort::OPTIONS.map { |k, label| [label, k] }, sort_key),
          {}, data: { action: "change->filter_form#submit" }, class: input_classes %>
  </label>
  <%= hidden_field_tag :dir, sort_dir %>
  <noscript><%= f.submit "Apply", class: "rounded-md bg-zinc-900 px-3 py-1.5 text-sm font-medium text-white dark:bg-white dark:text-zinc-900" %></noscript>
<% end %>
```

- [ ] **Step 5: Create `_facets.html.erb`**

```erb
<%# web/app/views/vulnerabilities/overview/_facets.html.erb
    A single GET form; changing any checkbox / date submits it (filter_form
    controller, already used by the search bar). Free-text q and sort are
    carried as hidden fields so a facet change preserves them. %>
<%
  wrap = "rounded-lg border border-zinc-200 bg-white p-4 dark:border-zinc-800 dark:bg-[#111315]"
  heading = "mb-2 text-xs font-semibold uppercase tracking-wider text-zinc-500 dark:text-zinc-400"
  vocab = { "severity" => VulnerabilitiesHelper::SEVERITIES, "status" => VulnerabilitiesHelper::STATUSES }
%>
<%= form_with url: vulnerabilities_root_path, method: :get,
      data: { controller: "filter_form" }, class: "space-y-5 #{wrap}" do %>
  <%= hidden_field_tag :q, filter_params[:q] if filter_params[:q].present? %>
  <%= hidden_field_tag :sort, filter_params[:sort] if filter_params[:sort].present? %>
  <%= hidden_field_tag :dir, filter_params[:dir] if filter_params[:dir].present? %>

  <% VulnerabilitiesHelper::FACET_DIMENSIONS.each do |dim| %>
    <% counts = result.facets[dim] || {} %>
    <%# Fixed-vocab dimensions always show every option; discovered dimensions
        (tool/type/program) show the values present in the data. %>
    <% values = vocab[dim] || counts.keys.sort %>
    <% next if values.empty? %>
    <fieldset>
      <legend class="<%= heading %>"><%= dim.humanize %></legend>
      <div class="space-y-1">
        <% selected = Array(filter_params[dim]).reject(&:blank?) %>
        <% values.each do |value| %>
          <label class="flex items-center justify-between gap-2 text-sm text-zinc-700 dark:text-zinc-300">
            <span class="flex items-center gap-2">
              <%= check_box_tag "#{dim}[]", value, selected.include?(value),
                    data: { action: "change->filter_form#submit" },
                    class: "rounded border-zinc-300 text-zinc-900 focus:ring-0 dark:border-zinc-600 dark:bg-zinc-800" %>
              <%= vuln_facet_label(dim, value) %>
            </span>
            <span class="text-xs tabular-nums text-zinc-400 dark:text-zinc-500"><%= counts[value] || 0 %></span>
          </label>
        <% end %>
      </div>
    </fieldset>
  <% end %>

  <fieldset>
    <legend class="<%= heading %>">Date</legend>
    <div class="flex items-center gap-2">
      <%= date_field_tag :date_from, filter_params[:date_from],
            data: { action: "change->filter_form#submit" },
            class: "w-full rounded-md border border-zinc-300 bg-white px-2 py-1 text-xs dark:border-zinc-700 dark:bg-[#0b0d0e] dark:text-zinc-100" %>
      <span class="text-xs text-zinc-400">–</span>
      <%= date_field_tag :date_to, filter_params[:date_to],
            data: { action: "change->filter_form#submit" },
            class: "w-full rounded-md border border-zinc-300 bg-white px-2 py-1 text-xs dark:border-zinc-700 dark:bg-[#0b0d0e] dark:text-zinc-100" %>
    </div>
  </fieldset>
<% end %>
```

- [ ] **Step 6: Create `_active_chips.html.erb`**

```erb
<%# web/app/views/vulnerabilities/overview/_active_chips.html.erb %>
<% chips = vuln_active_chips(filter_params) %>
<% if chips.any? %>
  <div class="flex flex-wrap items-center gap-2 border-b border-zinc-200 px-4 py-3 dark:border-zinc-800">
    <% chips.each do |chip| %>
      <%= link_to vulnerabilities_root_path(chip[:remove_params]),
            class: "inline-flex items-center gap-1 rounded-full border border-zinc-300 bg-zinc-50 px-2 py-0.5 text-xs text-zinc-600 hover:bg-zinc-100 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-300 dark:hover:bg-zinc-800" do %>
        <%= chip[:label] %>
        <span aria-hidden="true">&times;</span>
      <% end %>
    <% end %>
    <%= link_to "Clear all", vulnerabilities_root_path,
          class: "text-xs font-medium text-zinc-500 underline hover:text-zinc-800 dark:text-zinc-400 dark:hover:text-zinc-100" %>
  </div>
<% end %>
```

- [ ] **Step 7: Run test to verify it passes**

Run: `bin/rails test test/integration/vulnerabilities/overview_test.rb`
Expected: PASS.

- [ ] **Step 8: Run the full vulnerabilities suite**

Run: `bin/rails test test/services/vulnerabilities/ test/integration/vulnerabilities/ test/helpers/vulnerabilities_helper_test.rb`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git -c user.name="Claude" -c user.email="noreply@anthropic.com" add web/app/views/vulnerabilities/overview/
git -c user.name="Claude" -c user.email="noreply@anthropic.com" commit -m "Add faceted sidebar, active-filter chips, and sort control to the vulnerabilities overview."
```

---

### Task 8: Full-suite verification

**Files:** none (verification only).

- [ ] **Step 1: Run the entire test suite**

Run: `bin/rails test`
Expected: PASS with no regressions across the app.

- [ ] **Step 2: Manual smoke (optional, user runs Docker)**

The user runs the app in Docker. Suggested manual checks once up:
- `severity:high AND tool:nuclei` in the search bar narrows results and shows chips.
- Checking a severity box updates counts on the other dimensions but not its own.
- "Clear all" resets to the unfiltered list.
- Sort by Severity puts critical first.

- [ ] **Step 3: Commit (if any lint/fixups were needed)**

```bash
git -c user.name="Claude" -c user.email="noreply@anthropic.com" commit -am "Fix up vulnerability filter test/lint nits."
```

---

## Self-Review Notes

- **Spec coverage:** dork language (Tasks 1–2), faceted sidebar w/ counts (Tasks 5,7), active chips (Tasks 6–7), sort control (Tasks 3,7), free-text search (Tasks 4–5), Mongo-backed + in-memory fallback (Tasks 4–5), field mapping table (Task 1), other-filters facet semantics (Tasks 4–5), API left unchanged (no task touches `Api::V1::VulnerabilitiesController`). Port/date semantics reflect the spec update (port exact, date lexical range).
- **Parity invariant:** enforced by Task 1's data-driven `CASES` test asserting `to_mongo` and `evaluate` agree per key.
- **Type consistency:** `Query::Result` fields (`findings, total, facets, page, per_page, has_next, sort_key, sort_dir`) are used identically in Tasks 6–7. `Filter::FACET_FIELDS` and `Query::FACET_FIELDS` intentionally hold the same dimension keys in different shapes (reader tuple vs Mongo path). `Sort.mongo_doc`/`comparator`/`resolve_dir`/`resolve_key`/`SEVERITY_RANK` names match across Tasks 3 and 5.
