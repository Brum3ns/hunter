module ControlCenter
  # Read-only analytics over ControlCenter::Job (Postgres): one dashboard hash of
  # totals + breakdowns for the Statistics tab and the stats API. Parametrized AR
  # aggregates only; briefly cached; degrades to zeros/empties on error so the
  # tab never 500s.
  module JobStats
    module_function

    TOP_LIMIT = 8
    DAILY_DAYS = 30
    CACHE_KEY = "control_center:job_stats:dashboard".freeze
    CACHE_TTL = 60

    STATUS_COLORS = {
      "succeeded" => "#10b981",
      "failed" => "#f43f5e",
      "pending" => "#a1a1aa"
    }.freeze

    def dashboard
      Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_TTL) { compute }
    rescue StandardError
      empty
    end

    def compute
      counts = Job.group(:status).count
      succeeded = counts["succeeded"].to_i
      failed = counts["failed"].to_i
      pending = counts["pending"].to_i
      finished = succeeded + failed

      {
        totals: {
          jobs: counts.values.sum,
          succeeded: succeeded,
          failed: failed,
          pending: pending,
          success_rate: finished.zero? ? 0 : (succeeded * 100.0 / finished).round,
          targets: Job.sum(:target_count).to_i,
          templates_used: Job.distinct.count(:template_name)
        },
        by_status: STATUS_COLORS.map { |s, c| { label: s, count: counts[s].to_i, color: c } },
        top_templates: rank(Job.group(:template_name).count).first(TOP_LIMIT),
        by_queue: rank(Job.group(:queue_name).count),
        daily: daily_series
      }
    end

    # {key => count} -> [{label:, count:}] sorted by count desc.
    def rank(grouped)
      grouped.sort_by { |_k, n| -n }.map { |k, n| { label: k, count: n } }
    end

    def daily_series
      since = Date.current - (DAILY_DAYS - 1)
      rows = Job.where("created_at >= ?", since.beginning_of_day).group("created_at::date").count
      by_date = rows.transform_keys { |k| k.is_a?(Date) ? k : Date.parse(k.to_s) }
      (0...DAILY_DAYS).map do |i|
        d = since + i
        { date: d.iso8601, count: by_date[d].to_i }
      end
    end

    def empty
      {
        totals: { jobs: 0, succeeded: 0, failed: 0, pending: 0, success_rate: 0, targets: 0, templates_used: 0 },
        by_status: STATUS_COLORS.map { |s, c| { label: s, count: 0, color: c } },
        top_templates: [], by_queue: [], daily: []
      }
    end
  end
end
