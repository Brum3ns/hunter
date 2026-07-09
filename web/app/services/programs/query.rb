module Programs
  # Single entry point for the programs index page. At hundreds-to-thousands of
  # documents we cannot afford to materialize everything into Ruby just to
  # filter/sort — so this service translates filter_params into a Mongo `find`
  # plus a sort spec and returns only the matching rows.
  #
  # The in-memory `Programs::Filter` + `Programs::Sort` pipeline survives as a
  # fallback for the dev path (empty collection / Mongo unreachable) and for
  # any caller that already holds a Ruby list of Program PORO instances.
  #
  # Result also carries facets (platforms, scope_types, total, bounty_ceiling)
  # so the controller is a thin pass-through.
  class Query
    Result = Struct.new(:programs, :total, :platforms, :scope_types, :bounty_ceiling, :page, :per_page, :has_next, keyword_init: true)

    DEFAULT_PER_PAGE = 30
    MAX_PER_PAGE     = 100

    # Mongo field path for each sort key. Multi-field entries become compound
    # sorts (all fields share the same direction). Falls through to
    # Sort::DEFAULT_KEY if the param is unknown.
    SORT_FIELDS = {
      "name"          => ["name"],
      "date"          => ["updated_at", "date"],
      "bounty_max"    => ["bounty_max"],
      "bounty_min"    => ["bounty_min"],
      "reward_avg"    => ["reward_avg"],
      "reward_max"    => ["reward_max"],
      "reports"       => ["report_count"],
      "reports_24h"   => ["Total_reports_last24_hours"],
      "reports_7d"    => ["Total_reports_last7_days"],
      "reports_month" => ["Total_reports_current_month"],
      "response"      => ["Average_first_time_response"],
      "scope_count"   => ["scope_count"],
      "bounty"        => ["bounty"],
      "vdp"           => ["vdp"]
    }.freeze

    NUMERIC_MIN = {
      "bounty_min_gte"   => "bounty_min",
      "bounty_max_gte"   => "bounty_max",
      "reports_gte"      => "report_count",
      "reports_24h_gte"  => "Total_reports_last24_hours",
      "reports_7d_gte"   => "Total_reports_last7_days",
      "reports_month_gte" => "Total_reports_current_month",
      "scope_count_gte"  => "scope_count"
    }.freeze

    NUMERIC_MAX = {
      "scope_count_lte" => "scope_count",
      "response_lte"    => "Average_first_time_response"
    }.freeze

    DEFAULT_PLATFORMS = %w[hackerone bugcrowd intigriti yeswehack bugbountych].freeze

    def self.call(filter_params)
      new(filter_params).call
    end

    def initialize(filter_params)
      @params = filter_params
    end

    def call
      if mongo_usable?
        Programs::MongoSource.ensure_indexes_once!
        query_mongo
      else
        query_fallback
      end
    rescue Mongo::Error => e
      Rails.logger.warn("mongo: query failed, falling back (#{e.class}: #{e.message})")
      query_fallback
    end

    private

    def mongo_usable?
      return false unless Programs::MongoSource.healthy?
      Programs::MongoSource.collection.estimated_document_count.positive?
    rescue Mongo::Error
      false
    end

    def query_mongo
      match = match_doc
      total = Programs::MongoSource.collection.count_documents(match)
      offset = (page - 1) * per_page

      programs =
        if sort_by_favorites?
          fetch_with_favorites_sort(match, offset)
        else
          Programs::MongoSource.collection
            .find(match)
            .sort(sort_doc)
            .skip(offset)
            .limit(per_page)
            .map { |doc| Program.new(doc.transform_keys(&:to_s)) }
        end

      Result.new(
        programs:        programs,
        total:           total,
        platforms:       (DEFAULT_PLATFORMS + Programs::MongoSource.collection.distinct("platform")).compact.uniq.sort,
        scope_types:     canonical_scope_types_present_mongo,
        bounty_ceiling:  bounty_ceiling,
        page:            page,
        per_page:        per_page,
        has_next:        (offset + programs.size) < total
      )
    end

    # Collapse Mongo's distinct scope.type vocabulary into canonical
    # buckets so the sidebar shows e.g. one "Android" checkbox instead of
    # four ("Android", "GOOGLE_PLAY_APP_ID", "mobile-application-android",
    # "MOBILE_ANDROID"). Order follows ScopeType::CANONICAL.
    def canonical_scope_types_present_mongo
      raw = Programs::MongoSource.collection.distinct("scope.type").compact
      seen = raw.map { |t| Programs::ScopeType.canonical_for(t) }.to_set
      Programs::ScopeType::CANONICAL.select { |k| seen.include?(k) }.map(&:to_s)
    rescue Mongo::Error
      Programs::ScopeType::CANONICAL.map(&:to_s)
    end

    # Sort key "favorites" needs per-request state (the user's favorited sid
    # set), so it can't ride the static SORT_FIELDS path. Pipes through an
    # aggregation that computes a _fav rank, sorts by it, then paginates.
    def sort_by_favorites?
      @params[:sort].to_s == "favorites"
    end

    def fetch_with_favorites_sort(match, offset)
      sids = favorited_sids.to_a
      dir = Programs::Sort.resolve_dir("favorites", @params[:dir])
      sign = dir == "asc" ? 1 : -1
      pipeline = [
        { "$match" => match },
        { "$addFields" => { "_fav" => { "$cond" => [{ "$in" => ["$_sid", sids] }, 1, 0] } } },
        { "$sort" => { "_fav" => sign, "_sid" => sign } },
        { "$skip" => offset },
        { "$limit" => per_page }
      ]
      Programs::MongoSource.collection.aggregate(pipeline).map { |doc| Program.new(doc.transform_keys(&:to_s)) }
    end

    def query_fallback
      all = Programs::Source.all
      filtered = Programs::Filter.call(all, @params)
      sorted = Programs::Sort.call(filtered, @params[:sort], @params[:dir], favorited_sids: favorited_sids)
      offset = (page - 1) * per_page
      window = sorted[offset, per_page] || []

      Result.new(
        programs:        window,
        total:           sorted.size,
        platforms:       (DEFAULT_PLATFORMS + all.map(&:platform)).uniq.sort,
        scope_types:     Programs::ScopeType.canonicals_present(all).map(&:to_s),
        bounty_ceiling:  fallback_bounty_ceiling(all),
        page:            page,
        per_page:        per_page,
        has_next:        (offset + window.size) < sorted.size
      )
    end

    def page
      @page ||= [@params[:page].to_i, 1].max
    end

    def per_page
      @per_page ||= begin
        n = @params[:per_page].to_i
        n = DEFAULT_PER_PAGE if n <= 0
        [n, MAX_PER_PAGE].min
      end
    end

    # --- Mongo query construction -----------------------------------------

    def match_doc
      doc = {}
      add_search(doc)
      add_dork_expression(doc)
      add_in_list(doc, "platform", Array(@params[:platforms]))
      add_scope_type_canonical(doc, Array(@params[:scope_types]))
      add_bool(doc, "public", { "public" => true, "private" => false }, @params[:status])
      add_bool(doc, "bounty", { "with" => true, "without" => false },   @params[:bounty])
      add_bool(doc, "collaboration", { "yes" => true, "no" => false },  @params[:collaboration])
      add_favorites(doc)
      add_trash(doc)

      NUMERIC_MIN.each do |param_key, field|
        v = @params[param_key].to_f
        next unless v > 0
        merge_range(doc, field, "$gte", v)
      end
      NUMERIC_MAX.each do |param_key, field|
        v = @params[param_key].to_f
        next unless v > 0
        merge_range(doc, field, "$lte", v)
      end
      doc
    end

    def add_search(doc)
      q = @params[:q].to_s.strip
      return if q.empty?
      re = Regexp.escape(q)
      doc["$or"] = %w[slug name description].map { |f| { f => { "$regex" => re, "$options" => "i" } } } +
                   [
                     { "scope.asset"      => { "$regex" => re, "$options" => "i" } },
                     { "outofscope.asset" => { "$regex" => re, "$options" => "i" } }
                   ]
    end

    # Dork expression compiled by Programs::SearchParser. Always stacks
    # under $and so its (possibly $or-rooted) clause composes cleanly with
    # the broad free-text $or above and with the scalar sidebar filters.
    def add_dork_expression(doc)
      expr = @params[:dork_expression]
      return unless expr
      clause = expr.to_mongo
      return unless clause
      doc["$and"] = (doc["$and"] || []) + [clause]
    end

    def add_in_list(doc, field, values)
      cleaned = values.reject(&:blank?)
      return if cleaned.empty?
      doc[field] = { "$in" => cleaned }
    end

    # The sidebar's scope-type checkboxes carry canonical bucket keys
    # (:web, :android, ...). Expand each to the raw upstream tokens it
    # represents before matching against scope.type. If the user picked
    # "other" we cannot enumerate every unknown token, so we fall back
    # to "not in any known token list" via $nin.
    def add_scope_type_canonical(doc, values)
      keys = values.reject(&:blank?).map(&:to_s)
      return if keys.empty?
      known = keys - ["other"]
      tokens = Programs::ScopeType.expand(known)
      clauses = []
      clauses << { "scope.type" => { "$in" => tokens } } unless tokens.empty?
      if keys.include?("other")
        all_known = Programs::ScopeType.expand(Programs::ScopeType::CANONICAL)
        clauses << { "scope.type" => { "$nin" => all_known } }
      end
      return if clauses.empty?
      doc["$and"] = (doc["$and"] || []) + (clauses.size == 1 ? clauses : [{ "$or" => clauses }])
    end

    def add_bool(doc, field, mapping, value)
      return if value.blank?
      bool = mapping[value.to_s]
      doc[field] = bool unless bool.nil?
    end

    def add_favorites(doc)
      return unless @params[:favorites_only].to_s == "yes"
      sids = favorited_sids.to_a
      clause = { "_sid" => (sids.empty? ? { "$in" => ["__none__"] } : { "$in" => sids }) }
      doc["$and"] = (doc["$and"] || []) + [clause]
    end

    # Mirrors add_favorites: when "trash_only" is set, restrict the result
    # set to programs whose sid appears in the user's trash. $and-stacked
    # so it composes cleanly with favorites and dork expressions instead
    # of overwriting doc["_sid"].
    def add_trash(doc)
      return unless @params[:trash_only].to_s == "yes"
      sids = trashed_sids.to_a
      clause = { "_sid" => (sids.empty? ? { "$in" => ["__none__"] } : { "$in" => sids }) }
      doc["$and"] = (doc["$and"] || []) + [clause]
    end

    def favorited_sids
      @params[:_favorited_sids] || Set.new
    end

    def trashed_sids
      @params[:_trashed_sids] || Set.new
    end

    def merge_range(doc, field, op, value)
      doc[field] = (doc[field].is_a?(Hash) ? doc[field] : {}).merge(op => value)
    end

    def sort_doc
      key = SORT_FIELDS.key?(@params[:sort]) ? @params[:sort] : Programs::Sort::DEFAULT_KEY
      dir = Programs::Sort.resolve_dir(key, @params[:dir])
      sign = dir == "asc" ? 1 : -1
      doc = SORT_FIELDS[key].each_with_object({}) { |field, h| h[field] = sign }
      # Stable tiebreaker so paged windows don't shuffle rows whose primary
      # key ties — _sid is unique and indexed.
      doc["_sid"] = sign unless doc.key?("_sid")
      doc
    end

    def bounty_ceiling
      top = Programs::MongoSource.collection
        .find({ bounty_max: { "$gt" => 0 } })
        .projection(bounty_max: 1)
        .sort(bounty_max: -1)
        .limit(1)
        .first
      raw = top ? top["bounty_max"].to_f : 0.0
      round_ceiling(raw)
    end

    def fallback_bounty_ceiling(programs)
      round_ceiling(programs.map(&:bounty_max).max.to_f)
    end

    def round_ceiling(raw)
      return 1_000 if raw <= 0
      step = raw >= 10_000 ? 1_000 : 100
      (raw / step).ceil * step
    end
  end
end
