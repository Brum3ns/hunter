require "strscan"

module Sitemap
  # Splits the Sitemap search bar into broad free text and a typed dork AST.
  # Its grammar mirrors the other Hunter departments: adjacent terms imply
  # AND, AND binds tighter than OR, and parentheses override precedence.
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
          tokens << [ :lparen ]
        elsif scanner.scan(/\)/)
          tokens << [ :rparen ]
        elsif scanner.scan(/(?:&&|\band\b)/i)
          tokens << [ :and ]
        elsif scanner.scan(/(?:\|\||\bor\b)/i)
          tokens << [ :or ]
        elsif scanner.scan(/(\w+):(>=|<=|>|<)?(?:"([^"]+)"|([^\s()]+))/)
          key = scanner[1].downcase
          token = [ :term, key, scanner[2], scanner[3] || scanner[4] ]
          tokens << (KEYS.include?(key) ? token : [ :text, scanner.matched ])
        else
          word = scanner.scan(/\S+/)
          tokens << [ :text, word ] if word
        end
      end
      tokens
    end

    def demote_orphan_operators(tokens)
      tokens.each_with_index.map do |token, index|
        next token unless %i[and or].include?(token[0])

        previous = index.positive? ? tokens[index - 1] : nil
        following = tokens[index + 1]
        operand_like?(previous) && operand_like?(following) ? token : [ :text, token[0].to_s ]
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
      left_children = left.is_a?(type) ? left.children : [ left ]
      right_children = right.is_a?(type) ? right.children : [ right ]
      type.new(children: left_children + right_children)
    end
  end
end
