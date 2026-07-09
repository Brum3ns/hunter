require "strscan"

module Programs
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
  # AND binds tighter than OR (SQL-style), so
  #   asset:x.com AND program:test OR program:test2
  # parses as
  #   (asset:x.com AND program:test) OR program:test2
  #
  # AND / OR keywords are only treated as operators when both their
  # neighbors look like operands (term or paren). Otherwise they fall back
  # to free text so phrases like "cats or dogs" don't break.
  class SearchParser
    Result = Struct.new(:free_text, :expression, keyword_init: true)

    # Whitelist of keys the parser will recognize as dorks. An unknown key
    # like `foo:bar` is treated as free text rather than silently producing
    # an always-false clause. Keep in sync with DorkExpression::Mapper.
    KEYS = %w[
      asset program name slug org organization tag lang language
      platform mode bounty vdp active hof hall_of_fame
      reports reports_24h reports_7d reports_30d reports_month
      scope avg avg_reward max max_reward min min_reward response
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

    # AND/OR are only operators when sandwiched between two operand-shaped
    # neighbors. Otherwise demote to free text so plain prose like
    # "cats or dogs" (no dorks) doesn't get parsed as a boolean operator
    # with empty operands.
    def demote_orphan_operators(tokens)
      tokens.each_with_index.map do |tok, i|
        next tok unless %i[and or].include?(tok[0])
        prev_t = i > 0 ? tokens[i - 1] : nil
        next_t = tokens[i + 1]
        if operand_like?(prev_t) && operand_like?(next_t)
          tok
        else
          [:text, tok[0].to_s]
        end
      end
    end

    def operand_like?(t)
      t && OPERAND_TYPES.include?(t[0])
    end

    # --- recursive descent ------------------------------------------------

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

    # Flatten nested same-type nodes so `a OR b OR c` is one Or with three
    # children rather than nested binary Ors — keeps the emitted Mongo doc
    # compact and the Ruby evaluator's all?/any? short-circuit efficient.
    def combine(klass, left, right)
      left_kids  = left.is_a?(klass)  ? left.children  : [left]
      right_kids = right.is_a?(klass) ? right.children : [right]
      klass.new(children: left_kids + right_kids)
    end
  end
end
