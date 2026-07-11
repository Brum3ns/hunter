module Vulnerabilities
  # Read-only statistics over the vulnerabilities collection. Powers the overview
  # summary cards (via #summary) and the Statistics tab (via #dashboard).
  #
  # Performance: #dashboard resolves *every* panel in ONE aggregation using a
  # $facet — the collection is scanned a single time and fanned out to one
  # sub-pipeline per dimension, instead of a round trip per chart. The result is
  # then cached briefly so repeated views don't re-scan. Every read degrades to
  # zeros/empties on Mongo::Error rather than raising (mirrors MongoSource).
  #
  # Dates: metadata.date is stored as an ISO-8601 *string* (see Query's string
  # range filter), so timelines bucket by a substring of that string rather than
  # a date conversion, and only rows that start YYYY-MM-DD are counted.
  module Stats
    module_function

    REPORTED_STATUSES = %w[reported].freeze
    FALSE_POSITIVE_STATUSES = %w[false_positive fp].freeze
    CONFIDENCE_ORDER = %w[high medium low].freeze

    TOP_LIMIT = 8            # rows in a "top N" bar list
    TIMELINE_MONTHS = 12     # trailing months in the monthly chart
    DAILY_DAYS = 30          # trailing days in the "new findings" chart

    CACHE_KEY = "vulnerabilities:stats:dashboard".freeze
    CACHE_TTL = 60           # seconds; a stats dashboard tolerates minor staleness

    # ---- overview cards (cheap; its own tiny reads) ---------------------------

    def summary
      {
        created: count({}),
        reported: count("report.status" => { "$in" => REPORTED_STATUSES }),
        false_positives: count("report.status" => { "$in" => FALSE_POSITIVE_STATUSES })
      }
    rescue Mongo::Error => e
      warn_failed("summary", e)
      { created: 0, reported: 0, false_positives: 0 }
    end

    def count(filter)
      collection.count_documents(filter)
    end

    # ---- statistics dashboard (one query, cached) -----------------------------

    def dashboard
      Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_TTL) { compute_dashboard }
    end

    # Runs the single $facet aggregation and shapes each sub-result into the
    # structure the views consume.
    def compute_dashboard
      raw = collection.aggregate([{ "$facet" => dashboard_facets }]).first || {}
      status_rows = raw["status"]
      daily_rows = raw["daily"]
      total = Array(raw["total"]).first&.fetch("count", 0).to_i

      {
        total: total,
        summary: {
          created: total,
          reported: sum_matching(status_rows, REPORTED_STATUSES),
          false_positives: sum_matching(status_rows, FALSE_POSITIVE_STATUSES)
        },
        new_7d: recent_total(daily_rows, 7),
        new_30d: recent_total(daily_rows, 30),
        severity: ordered_from(raw["severity"], VulnerabilitiesHelper::SEVERITIES, "info"),
        status: ordered_from(status_rows, VulnerabilitiesHelper::STATUSES, "new"),
        methods: labelled_from(raw["method"], upcase: true),
        confidence: confidence_from(raw["confidence"]),
        submitted: submitted_from(raw["submitted"], total),
        types: top_from(raw["type"]),
        tools: top_from(raw["tool"]),
        programs: top_from(raw["program"]),
        cwes: top_from(raw["cwe"]),
        hosts: top_from(raw["host"]),
        tags: top_from(raw["tags"]),
        timeline: monthly_from(raw["monthly"], TIMELINE_MONTHS),
        daily: daily_from(daily_rows, DAILY_DAYS)
      }
    rescue Mongo::Error => e
      warn_failed("dashboard", e)
      empty_dashboard
    end

    def collection
      HunterMongo.collection(MongoSource::COLLECTION)
    end

    # ---- $facet sub-pipelines -------------------------------------------------

    def dashboard_facets
      {
        "total"      => [{ "$count" => "count" }],
        "severity"   => group_by("finding.severity"),
        "status"     => group_by("report.status"),
        "method"     => group_by("target.method"),
        "confidence" => group_by("poc.confidence"),
        "submitted"  => group_by("report.submitted"),
        "type"       => top_by("finding.type"),
        "tool"       => top_by("metadata.tool"),
        "program"    => top_by("metadata.program"),
        "cwe"        => top_by("finding.cwe"),
        "host"       => top_by("target.host"),
        "tags"       => unwind_top_by("finding.tags"),
        "monthly"    => date_bucket(7),
        "daily"      => date_bucket(10)
      }
    end

    # Count documents per distinct value of a scalar field.
    def group_by(field)
      [{ "$group" => { "_id" => "$#{field}", "count" => { "$sum" => 1 } } }]
    end

    # Busiest values first, capped — keeps high-cardinality facets (hosts, tags)
    # from returning thousands of rows.
    def top_by(field, limit: TOP_LIMIT)
      group_by(field) + [{ "$sort" => { "count" => -1, "_id" => 1 } }, { "$limit" => limit }]
    end

    # Same, over an array field (tags): one count per element occurrence.
    def unwind_top_by(field, limit: TOP_LIMIT)
      [{ "$unwind" => "$#{field}" }] + top_by(field, limit: limit)
    end

    # Bucket the ISO date string by a prefix length: 7 -> "YYYY-MM" (month),
    # 10 -> "YYYY-MM-DD" (day). The regex gate skips blank/non-ISO dates so a
    # stray value can't produce a junk bucket.
    def date_bucket(prefix_length)
      [
        { "$match" => { "metadata.date" => { "$regex" => "^[0-9]{4}-[0-9]{2}-[0-9]{2}" } } },
        { "$group" => { "_id" => { "$substrCP" => ["$metadata.date", 0, prefix_length] }, "count" => { "$sum" => 1 } } }
      ]
    end

    # ---- row -> panel transforms (pure; operate on aggregation rows) ----------

    # Collapse rows onto a fixed vocabulary: one zero-filled bucket per vocab
    # entry in canonical order; out-of-vocab values fold into `fallback`.
    def ordered_from(rows, vocab, fallback)
      counts = Hash.new(0)
      Array(rows).each do |row|
        key = row["_id"].to_s.downcase.strip
        key = fallback unless vocab.include?(key)
        counts[key] += row["count"].to_i
      end
      vocab.map { |value| { key: value, label: value.humanize, count: counts[value] } }
    end

    # Free-vocabulary rows, biggest first, capped; blanks labelled "unknown".
    def top_from(rows, limit = TOP_LIMIT)
      Array(rows)
        .map { |row| { key: row["_id"].to_s, label: row["_id"].to_s.presence || "unknown", count: row["count"].to_i } }
        .reject { |bucket| bucket[:count].zero? }
        .sort_by { |bucket| [-bucket[:count], bucket[:label]] }
        .first(limit)
    end

    # Small scalar distribution kept in count order, blanks labelled "unknown".
    def labelled_from(rows, upcase: false)
      Array(rows)
        .map do |row|
          raw = row["_id"].to_s
          label = raw.blank? ? "unknown" : (upcase ? raw.upcase : raw)
          { key: raw, label: label, count: row["count"].to_i }
        end
        .reject { |bucket| bucket[:count].zero? }
        .sort_by { |bucket| -bucket[:count] }
    end

    def confidence_from(rows)
      counts = Hash.new(0)
      Array(rows).each do |row|
        key = row["_id"].to_s.downcase.strip
        key = "unrated" unless CONFIDENCE_ORDER.include?(key)
        counts[key] += row["count"].to_i
      end
      (CONFIDENCE_ORDER + %w[unrated]).filter_map do |key|
        next if counts[key].zero?
        { key: key, label: key.humanize, count: counts[key] }
      end
    end

    # report.submitted is a boolean; everything that isn't true (false or unset)
    # counts as not-yet-submitted, so the two rows always sum to the total.
    def submitted_from(rows, total)
      submitted = Array(rows).sum { |row| row["_id"] == true ? row["count"].to_i : 0 }
      [
        { key: "submitted", label: "Submitted", count: submitted, color: "text-emerald-500" },
        { key: "not_submitted", label: "Not submitted", count: [total - submitted, 0].max, color: "text-zinc-400" }
      ]
    end

    # Trailing `months` ending this month, zero-filled. Rows are { "YYYY-MM" => n }.
    def monthly_from(rows, months)
      counts = counts_from(rows)
      start = Date.current.beginning_of_month.prev_month(months - 1)
      (0...months).map do |i|
        date = start.next_month(i)
        key = date.strftime("%Y-%m")
        { key: key, label: date.strftime("%b"), year: date.year, count: counts[key] || 0 }
      end
    end

    # Trailing `days` ending today, zero-filled. Rows are { "YYYY-MM-DD" => n }.
    def daily_from(rows, days)
      counts = counts_from(rows)
      start = Date.current - (days - 1)
      (0...days).map do |i|
        date = start + i
        key = date.strftime("%Y-%m-%d")
        { key: key, label: date.strftime("%-d %b"), count: counts[key] || 0 }
      end
    end

    # Sum of the last `days` daily buckets. ISO date strings compare
    # lexicographically, so a string >= cutoff is a within-window test.
    def recent_total(rows, days)
      cutoff = (Date.current - (days - 1)).strftime("%Y-%m-%d")
      Array(rows).sum { |row| row["_id"].to_s >= cutoff ? row["count"].to_i : 0 }
    end

    # ---- internals ------------------------------------------------------------

    def counts_from(rows)
      Array(rows).each_with_object(Hash.new(0)) { |row, acc| acc[row["_id"]] += row["count"].to_i }
    end

    def sum_matching(rows, wanted)
      set = wanted.map(&:downcase)
      Array(rows).sum { |row| set.include?(row["_id"].to_s.downcase) ? row["count"].to_i : 0 }
    end

    def empty_dashboard
      {
        total: 0,
        summary: { created: 0, reported: 0, false_positives: 0 },
        new_7d: 0,
        new_30d: 0,
        severity: ordered_from([], VulnerabilitiesHelper::SEVERITIES, "info"),
        status: ordered_from([], VulnerabilitiesHelper::STATUSES, "new"),
        methods: [],
        confidence: [],
        submitted: submitted_from([], 0),
        types: [], tools: [], programs: [], cwes: [], hosts: [], tags: [],
        timeline: monthly_from([], TIMELINE_MONTHS),
        daily: daily_from([], DAILY_DAYS)
      }
    end

    def warn_failed(where, error)
      Rails.logger.warn("Vulnerabilities::Stats##{where} failed (#{error.class}: #{error.message})")
    end
  end
end
