# View helpers scoped to the vulnerability-management department. Kept module-
# local so severity/status vocab and the monochrome ramp change in one place
# without touching other modules.
module VulnerabilitiesHelper
  SEVERITIES = %w[critical high medium low info].freeze
  STATUSES = %w[new triage reported close false_positive].freeze

  def severity_select_options
    SEVERITIES.map { |value| [value.humanize, value] }
  end

  def status_select_options
    STATUSES.map { |value| [value.humanize, value] }
  end

  # Legacy/blank Mongo statuses render as "new"; recognized values pass through.
  def display_status(raw)
    value = raw.to_s.downcase
    STATUSES.include?(value) ? value : "new"
  end

  # Severity ramp. Deliberate, contained break from the app's monochrome design:
  # only these table badges carry color. info stays gray. Dark-mode variants
  # included. Tailwind v4 auto-scans this .rb, so literal classes are not purged.
  SEVERITY_CLASSES = {
    "critical" => "bg-red-100 text-red-700 dark:bg-red-950 dark:text-red-300",
    "high"     => "bg-orange-100 text-orange-700 dark:bg-orange-950 dark:text-orange-300",
    "medium"   => "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300",
    "low"      => "bg-blue-100 text-blue-700 dark:bg-blue-950 dark:text-blue-300",
    "info"     => "bg-zinc-200 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-400"
  }.freeze

  def severity_badge_classes(severity)
    SEVERITY_CLASSES.fetch(severity.to_s.downcase, SEVERITY_CLASSES["info"])
  end

  # Status ramp for the editable pill. Each state carries its own hue so the
  # workflow stage reads at a glance. Dark-mode variants included; Tailwind v4
  # auto-scans this .rb, so literal classes survive purging.
  STATUS_CLASSES = {
    "new"            => "bg-sky-100 text-sky-700 ring-sky-600/20 dark:bg-sky-950 dark:text-sky-300 dark:ring-sky-400/25",
    "triage"         => "bg-amber-100 text-amber-800 ring-amber-600/20 dark:bg-amber-950 dark:text-amber-300 dark:ring-amber-400/25",
    "reported"       => "bg-emerald-100 text-emerald-700 ring-emerald-600/20 dark:bg-emerald-950 dark:text-emerald-300 dark:ring-emerald-400/25",
    "close"          => "bg-zinc-200 text-zinc-600 ring-zinc-500/20 dark:bg-zinc-800 dark:text-zinc-300 dark:ring-zinc-400/25",
    "false_positive" => "bg-rose-100 text-rose-700 ring-rose-600/20 dark:bg-rose-950 dark:text-rose-300 dark:ring-rose-400/25"
  }.freeze

  def status_badge_classes(status)
    STATUS_CLASSES.fetch(display_status(status), STATUS_CLASSES["new"])
  end

  # Solid chart hues for the Statistics tab, applied via `bg-current` (bars,
  # legend swatches) or `stroke="currentColor"` (donut). Distinct from the badge
  # ramps above: a chart wants one saturated fill per bucket, not a tinted pill.
  # Tailwind v4 auto-scans this .rb, so these literal classes survive purging.
  SEVERITY_CHART_COLORS = {
    "critical" => "text-red-500",
    "high"     => "text-orange-500",
    "medium"   => "text-amber-500",
    "low"      => "text-blue-500",
    "info"     => "text-zinc-400"
  }.freeze

  def severity_chart_color(severity)
    SEVERITY_CHART_COLORS.fetch(severity.to_s.downcase, "text-zinc-400")
  end

  STATUS_CHART_COLORS = {
    "new"            => "text-sky-500",
    "triage"         => "text-amber-500",
    "reported"       => "text-emerald-500",
    "close"          => "text-zinc-400",
    "false_positive" => "text-rose-500"
  }.freeze

  def status_chart_color(status)
    STATUS_CHART_COLORS.fetch(display_status(status), "text-zinc-400")
  end

  # Facet dimensions that render as multi-select checkbox groups, in order.
  FACET_DIMENSIONS = %w[severity status tool type program].freeze

  # Human label for a facet value (severity/status humanize; others verbatim).
  def vuln_facet_label(dim, value)
    %w[severity status].include?(dim) ? value.to_s.humanize : value.to_s
  end

  # Active-filter chips: one per free-text query, per selected facet value, and
  # per date bound. Each carries the param hash to link to when removed.
  def vuln_active_chips(params)
    chips = []
    chips << { label: %(search: "#{params[:q]}"), remove_params: vuln_chip_params_without(params, :q) } if params[:q].present?
    FACET_DIMENSIONS.each do |dim|
      Array(params[dim]).reject(&:blank?).each do |value|
        chips << { label: "#{dim}: #{vuln_facet_label(dim, value)}", remove_params: vuln_chip_params_without(params, dim, value) }
      end
    end
    { date_from: "from", date_to: "to" }.each do |key, word|
      chips << { label: "#{word}: #{params[key]}", remove_params: vuln_chip_params_without(params, key) } if params[key].present?
    end
    chips
  end

  # Copy of the current filter params with one value removed: the whole key for
  # scalars, or a single element for a multi-select dimension. Page is reset.
  def vuln_chip_params_without(params, key, value = nil)
    key = key.to_s
    copy = params.to_h.deep_dup.with_indifferent_access
    copy.delete(:page)
    if value && copy[key].is_a?(Array)
      copy[key] = copy[key] - [value]
      copy.delete(key) if copy[key].empty?
    else
      copy.delete(key)
    end
    copy
  end

  # Table columns that can be sorted, in table order: label => Sort key.
  # Target and Tool have no Sort key, so they render as plain headers.
  SORTABLE_COLUMNS = { "Severity" => "severity", "Status" => "status", "Name" => "name", "Date" => "date" }.freeze

  # URL params that sort the findings list by `key`: toggles direction when the
  # column is already active, otherwise uses that key's natural default. Keeps
  # the current filters and drops pagination.
  def vuln_sort_params(params, key, current_key, current_dir)
    dir =
      if key.to_s == current_key.to_s
        current_dir.to_s == "asc" ? "desc" : "asc"
      else
        Vulnerabilities::Sort.resolve_dir(key, nil)
      end
    params.to_h.with_indifferent_access.merge("sort" => key, "dir" => dir).except("page")
  end

  # Arrow shown on a sortable header: a direction arrow for the active column,
  # a faint two-way arrow for the rest.
  def vuln_sort_indicator(key, current_key, current_dir)
    return current_dir.to_s == "asc" ? "↑" : "↓" if key.to_s == current_key.to_s

    "↕"
  end
end
