module Targets
  # AST nodes the Target search bar emits, plus the Mapper that owns per-key
  # Mongo semantics. Mirrors Vulnerabilities::DorkExpression but adapted to the
  # `alive` document and Mongo-only (the Target list queries Mongo directly, so
  # there is no in-memory evaluate path to keep in parity).
  #
  # Supported keys (see Targets::SearchParser::KEYS):
  #   host url ip path title webserver content_type program tool page_type
  #   scheme tech   -> case-insensitive substring, `*` acts as a wildcard
  #   method port                                   -> exact (or wildcard)
  #   status                                        -> numeric, supports > >= < <=
  module DorkExpression
    Term = Struct.new(:key, :op, :value, keyword_init: true) do
      def to_mongo = Mapper.to_mongo(key, op, value)
    end

    And = Struct.new(:children, keyword_init: true) do
      def to_mongo
        clauses = children.map(&:to_mongo).compact
        return nil           if clauses.empty?
        return clauses.first if clauses.size == 1
        { "$and" => clauses }
      end
    end

    Or = Struct.new(:children, keyword_init: true) do
      def to_mongo
        clauses = children.map(&:to_mongo).compact
        return nil           if clauses.empty?
        return clauses.first if clauses.size == 1
        { "$or" => clauses }
      end
    end

    module Mapper
      RANGE_OPS = { ">" => "$gt", ">=" => "$gte", "<" => "$lt", "<=" => "$lte" }.freeze

      # key -> Mongo field for the substring/wildcard text keys.
      TEXT_FIELDS = {
        "host" => "target.host", "url" => "target.url", "ip" => "target.ip",
        "path" => "target.path", "scheme" => "target.scheme", "title" => "http.title",
        "webserver" => "http.webserver", "content_type" => "http.content_type",
        "program" => "metadata.program", "tool" => "metadata.tool",
        "page_type" => "fingerprint.page_type", "tech" => "tech"
      }.freeze

      module_function

      def to_mongo(key, op, value)
        key = key.to_s
        return text_clause(TEXT_FIELDS[key], value) if TEXT_FIELDS.key?(key)

        case key
        when "method" then exact_clause("target.method", value)
        when "port"   then exact_clause("target.port", value)
        when "status" then status_clause(op, value)
        end
      end

      # Case-insensitive substring match; `*` becomes a wildcard (anchored). On
      # the array field `tech`, Mongo matches if ANY element matches.
      def text_clause(field, value)
        return nil if value.to_s.empty?
        { field => { "$regex" => regex_for(value), "$options" => "i" } }
      end

      # Exact match (anchored), or a wildcard when `*` is present.
      def exact_clause(field, value)
        return nil if value.to_s.empty?
        pattern = value.include?("*") ? regex_for(value) : "\\A#{Regexp.escape(value)}\\z"
        { field => { "$regex" => pattern, "$options" => "i" } }
      end

      # status_code is stored as an integer, so compare numerically.
      def status_clause(op, value)
        return nil if value.to_s.empty?
        if op && RANGE_OPS[op]
          { "http.status_code" => { RANGE_OPS[op] => value.to_i } }
        else
          { "http.status_code" => value.to_i }
        end
      end

      # Substring by default; translate `*` to `.*` and anchor when present.
      def regex_for(value)
        if value.include?("*")
          "\\A#{value.split("*", -1).map { |part| Regexp.escape(part) }.join(".*")}\\z"
        else
          Regexp.escape(value)
        end
      end
    end
  end
end
