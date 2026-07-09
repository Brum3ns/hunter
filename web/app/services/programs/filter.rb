module Programs
  class Filter
    NUMERIC_MIN = {
      bounty_min:   :bounty_min,
      bounty_max:   :bounty_max,
      reports:      :report_count,
      reports_24h:  :reports_24h,
      reports_7d:   :reports_7d,
      reports_month: :reports_month
    }.freeze

    def self.call(programs, params)
      new(programs, params).call
    end

    def initialize(programs, params)
      @programs = programs
      @params = params
    end

    def call
      progs = @programs
      progs = by_search(progs)
      progs = by_dork_expression(progs)
      progs = by_platforms(progs)
      progs = by_status(progs)
      progs = by_bounty(progs)
      progs = by_collaboration(progs)
      progs = by_favorites(progs)
      progs = by_trash(progs)
      progs = by_scope_types(progs)
      progs = by_scope_count_range(progs)
      progs = by_response_max(progs)
      NUMERIC_MIN.each { |param_key, attr| progs = by_min(progs, attr, @params["#{param_key}_gte"]) }
      progs
    end

    private

    def by_favorites(progs)
      return progs unless @params[:favorites_only].to_s == "yes"
      set = @params[:_favorited_sids] || Set.new
      progs.select { |p| set.include?(p.sid) }
    end

    def by_trash(progs)
      return progs unless @params[:trash_only].to_s == "yes"
      set = @params[:_trashed_sids] || Set.new
      progs.select { |p| set.include?(p.sid) }
    end

    def by_search(progs)
      q = @params[:q].to_s.strip.downcase
      return progs if q.empty?

      progs.select do |p|
        haystack = [
          p.slug, p.name, p.description,
          *p.scope.flat_map { |s| [ s["asset"], s["value"] ] },
          *p.out_of_scope.map { |s| s["asset"] }
        ].compact.join(" ").downcase
        haystack.include?(q)
      end
    end

    # Apply the parsed dork AST (DorkExpression::And/Or/Term) against each
    # program. The Mapper inside the AST handles all per-key semantics, so
    # this method only orchestrates the per-program evaluation.
    def by_dork_expression(progs)
      expr = @params[:dork_expression]
      return progs unless expr
      progs.select { |p| expr.evaluate(p) }
    end

    def by_platforms(progs)
      values = Array(@params[:platforms]).reject(&:blank?)
      return progs if values.empty?
      progs.select { |p| values.include?(p.platform) }
    end

    def by_status(progs)
      case @params[:status]
      when "public"  then progs.select(&:public?)
      when "private" then progs.reject(&:public?)
      else progs
      end
    end

    def by_bounty(progs)
      case @params[:bounty]
      when "with"    then progs.select(&:bounty?)
      when "without" then progs.reject(&:bounty?)
      else progs
      end
    end

    def by_collaboration(progs)
      case @params[:collaboration]
      when "yes" then progs.select(&:collaboration?)
      when "no"  then progs.reject(&:collaboration?)
      else progs
      end
    end

    def by_scope_types(progs)
      values = Array(@params[:scope_types]).reject(&:blank?)
      return progs if values.empty?
      expanded = Programs::ScopeType.expand(values).map(&:downcase)
      progs.select do |p|
        p.scope.any? do |s|
          tok = s["type"].to_s.downcase
          expanded.include?(tok) ||
            (values.include?("other") && Programs::ScopeType.canonical_for(s["type"]) == :other)
        end
      end
    end

    def by_scope_count_range(progs)
      progs = by_min(progs, :scope_count, @params[:scope_count_gte])
      progs = by_max(progs, :scope_count, @params[:scope_count_lte])
      progs
    end

    def by_response_max(progs)
      by_max(progs, :avg_response_hrs, @params[:response_lte])
    end

    def by_min(progs, attr, value)
      threshold = value.to_f
      return progs if value.blank? || threshold <= 0
      progs.select { |p| p.public_send(attr) >= threshold }
    end

    def by_max(progs, attr, value)
      threshold = value.to_f
      return progs if value.blank? || threshold <= 0
      progs.select { |p| p.public_send(attr) <= threshold }
    end
  end
end
