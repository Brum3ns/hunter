require "date"

module Sitemap
  # Typed search AST plus the only mapping from public dork keys to the
  # relational Sitemap projection. Predicates are composed as quoted Arel
  # nodes; user input is never interpolated into SQL.
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
        when "has_query"
          boolean_arel(Sitemap::Endpoint.arel_table[:url].matches("%?%", nil, false), value)
        when "root"
          boolean_arel(Sitemap::Endpoint.arel_table[:path].eq("/"), value)
        when "seen"
          date_arel(Sitemap::Endpoint.arel_table[:last_seen_at], op, value)
        else
          false_arel
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
        false if FALSE_VALUES.include?(normalized)
      end

      def false_arel
        Arel::Nodes::Equality.new(Arel::Nodes.build_quoted(1), Arel::Nodes.build_quoted(0))
      end

      def text_arel(field, value)
        field.matches(pattern(value, substring: true), nil, false)
      end

      def exact_arel(field, value)
        if value.to_s.include?("*")
          field.matches(pattern(value, substring: false), nil, false)
        else
          Arel::Nodes::NamedFunction.new("LOWER", [ field ]).eq(value.to_s.downcase)
        end
      end

      def number_arel(field, op, value)
        number = Integer(value, 10)
        op ? field.public_send(RANGE_METHODS.fetch(op), number) : field.eq(number)
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
