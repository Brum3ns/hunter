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
      # field (tags) Mongo matches if ANY element matches. The needle is
      # downcased for a canonical clause; the `i` option makes case moot anyway.
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
