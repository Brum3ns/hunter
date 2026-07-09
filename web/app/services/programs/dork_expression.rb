module Programs
  # AST nodes the search parser emits, plus the Mapper that owns all per-key
  # semantics. Every supported dork key has two implementations side-by-side
  # in Mapper: `to_mongo` for the indexed Mongo path, `evaluate` for the
  # in-memory fallback. They live in one file specifically so a key cannot be
  # added on one path without the other.
  module DorkExpression
    # A single condition like `asset:example.com` or `reports:>=10`. The key
    # is already downcased and validated by the parser before reaching here.
    Term = Struct.new(:key, :op, :value, keyword_init: true) do
      def to_mongo            = Mapper.to_mongo(key, op, value)
      def evaluate(program)   = Mapper.evaluate(program, key, op, value)
    end

    # n-ary boolean conjunction. Compiled to `{ "$and": [...] }` for Mongo
    # and `all?` for the Ruby evaluator. A single child returns directly
    # (no wrapping clause) so the emitted Mongo doc stays minimal.
    And = Struct.new(:children, keyword_init: true) do
      def to_mongo
        clauses = children.map(&:to_mongo).compact
        return nil           if clauses.empty?
        return clauses.first if clauses.size == 1
        { "$and" => clauses }
      end
      def evaluate(program) = children.all? { |c| c.evaluate(program) }
    end

    # n-ary boolean disjunction. Symmetric to And.
    Or = Struct.new(:children, keyword_init: true) do
      def to_mongo
        clauses = children.map(&:to_mongo).compact
        return nil           if clauses.empty?
        return clauses.first if clauses.size == 1
        { "$or" => clauses }
      end
      def evaluate(program) = children.any? { |c| c.evaluate(program) }
    end

    # Single source of truth for per-key dork semantics. Adding a new dork
    # means adding ONE branch to both `to_mongo` and `evaluate` — keep them
    # adjacent so reviewers can spot divergence at a glance.
    module Mapper
      PLATFORM_ALIASES = {
        "h1"          => "hackerone",
        "hackerone"   => "hackerone",
        "bc"          => "bugcrowd",
        "bugcrowd"    => "bugcrowd",
        "intigriti"   => "intigriti",
        "ywh"         => "yeswehack",
        "yeswehack"   => "yeswehack",
        "bbch"        => "bugbountych",
        "bugbountych" => "bugbountych"
      }.freeze

      BOOL_TRUE  = %w[true yes y 1 on].freeze
      BOOL_FALSE = %w[false no n 0 off].freeze

      RANGE_OPS_MONGO = { ">" => "$gt", ">=" => "$gte", "<" => "$lt", "<=" => "$lte" }.freeze

      module_function

      def to_mongo(key, op, value)
        case key
        when "asset"            then regex_or(%w[scope.asset outofscope.asset], value)
        when "program"          then regex_or(%w[slug name], value)
        when "name"             then regex_field("name", value)
        when "slug"             then regex_field("slug", value)
        when "org", "organization"
          regex_or(%w[organization.name organization.slug], value)
        when "tag"              then { "tags" => value }
        when "lang", "language" then { "languages" => value }
        when "platform"         then platform_clause(value)
        when "mode"             then mode_clause(value)
        when "bounty"           then bool_clause("bounty", value)
        when "vdp"              then bool_clause("vdp", value)
        when "active"           then bool_clause("collaboration", value)
        when "hof", "hall_of_fame" then bool_clause("hall_of_fame", value)
        when "reports"          then range_mongo("report_count", op, value, default_op: ">=")
        when "reports_24h"      then range_mongo("Total_reports_last24_hours", op, value, default_op: ">=")
        when "reports_7d"       then range_mongo("Total_reports_last7_days", op, value, default_op: ">=")
        when "reports_30d", "reports_month"
          range_mongo("Total_reports_current_month", op, value, default_op: ">=")
        when "scope"            then range_mongo("scope_count", op, value, default_op: ">=")
        when "avg", "avg_reward" then range_mongo("reward_avg", op, value, default_op: ">=")
        when "max", "max_reward" then range_mongo("reward_max", op, value, default_op: ">=")
        when "min", "min_reward" then range_mongo("bounty_min", op, value, default_op: ">=")
        when "response"         then range_mongo("Average_first_time_response", op, value, default_op: "<=")
        end
      end

      def evaluate(program, key, op, value)
        case key
        when "asset"            then asset_substring?(program, value)
        when "program"          then text_in?(value, program.slug, program.name)
        when "name"             then text_in?(value, program.name)
        when "slug"             then text_in?(value, program.slug)
        when "org", "organization"
          org = program.organization
          org && text_in?(value, org["name"], org["slug"])
        when "tag"              then list_member?(program.tags, value)
        when "lang", "language" then list_member?(program.languages, value)
        when "platform"
          normalized = PLATFORM_ALIASES[value.to_s.downcase]
          !!normalized && program.platform == normalized
        when "mode"
          case value.to_s.downcase
          when "public"  then !!program.public?
          when "private" then !program.public?
          else false
          end
        when "bounty"           then bool_eval(value, program.bounty?)
        when "vdp"              then bool_eval(value, program.vdp?)
        when "active"           then bool_eval(value, program.collaboration?)
        when "hof", "hall_of_fame" then bool_eval(value, program.hall_of_fame?)
        when "reports"          then range_eval(program.report_count, op, value, ">=")
        when "reports_24h"      then range_eval(program.reports_24h, op, value, ">=")
        when "reports_7d"       then range_eval(program.reports_7d, op, value, ">=")
        when "reports_30d", "reports_month"
          range_eval(program.reports_month, op, value, ">=")
        when "scope"            then range_eval(program.scope_count, op, value, ">=")
        when "avg", "avg_reward" then range_eval(program.reward_avg, op, value, ">=")
        when "max", "max_reward" then range_eval(program.reward_max, op, value, ">=")
        when "min", "min_reward" then range_eval(program.bounty_min, op, value, ">=")
        when "response"         then range_eval(program.avg_response_hrs, op, value, "<=")
        else false
        end
      end

      # ---- mongo builders --------------------------------------------------

      def regex_or(fields, value)
        return nil if value.to_s.empty?
        re = Regexp.escape(value)
        { "$or" => fields.map { |f| { f => { "$regex" => re, "$options" => "i" } } } }
      end

      def regex_field(field, value)
        return nil if value.to_s.empty?
        { field => { "$regex" => Regexp.escape(value), "$options" => "i" } }
      end

      def platform_clause(value)
        normalized = PLATFORM_ALIASES[value.to_s.downcase]
        normalized && { "platform" => normalized }
      end

      def mode_clause(value)
        case value.to_s.downcase
        when "public"  then { "public" => true }
        when "private" then { "public" => false }
        end
      end

      def bool_clause(field, value)
        v = value.to_s.downcase
        return { field => true }  if BOOL_TRUE.include?(v)
        return { field => false } if BOOL_FALSE.include?(v)
        nil
      end

      def range_mongo(field, op, value, default_op:)
        n = parse_num(value)
        return nil unless n
        mongo_op = RANGE_OPS_MONGO[op.presence || default_op]
        return nil unless mongo_op
        { field => { mongo_op => n } }
      end

      # ---- ruby evaluators -------------------------------------------------

      def asset_substring?(program, value)
        needle = value.to_s.downcase
        return false if needle.empty?
        assets = program.scope.map { |s| s["asset"] } + program.out_of_scope.map { |s| s["asset"] }
        assets.compact.any? { |a| a.to_s.downcase.include?(needle) }
      end

      def text_in?(needle, *haystacks)
        n = needle.to_s.downcase
        return false if n.empty?
        haystacks.compact.any? { |h| h.to_s.downcase.include?(n) }
      end

      def list_member?(list, value)
        v = value.to_s.downcase
        Array(list).any? { |x| x.to_s.downcase == v }
      end

      def bool_eval(value, actual)
        v = value.to_s.downcase
        return !!actual  == true  if BOOL_TRUE.include?(v)
        return !!actual  == false if BOOL_FALSE.include?(v)
        false
      end

      def range_eval(actual, op, value, default_op)
        n = parse_num(value)
        return false unless n
        case op.presence || default_op
        when ">"  then actual.to_f >  n
        when ">=" then actual.to_f >= n
        when "<"  then actual.to_f <  n
        when "<=" then actual.to_f <= n
        else false
        end
      end

      def parse_num(value)
        v = value.to_s
        return nil if v.empty?
        Float(v)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
