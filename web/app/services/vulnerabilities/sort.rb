module Vulnerabilities
  # Sort options for the findings list. Each key maps to a Mongo field (for the
  # indexed path) and an in-memory comparator (for the fallback). Severity sorts
  # by a fixed rank, not alphabetically.
  module Sort
    module_function

    DEFAULT_KEY = "date"

    OPTIONS = {
      "date"     => "Date",
      "severity" => "Severity",
      "status"   => "Status",
      "program"  => "Program",
      "name"     => "Name"
    }.freeze

    # Default direction per key: newest dates and highest severity first; every
    # other key ascends. Default set before freezing (can't mutate a frozen Hash).
    DEFAULT_DIR = Hash.new("asc").merge("date" => "desc", "severity" => "desc").freeze

    FIELDS = {
      "date"     => "metadata.date",
      "status"   => "report.status",
      "program"  => "metadata.program",
      "name"     => "finding.name"
    }.freeze

    # High number = more severe, so "desc" puts critical on top.
    SEVERITY_RANK = { "critical" => 5, "high" => 4, "medium" => 3, "low" => 2, "info" => 1 }.freeze

    def resolve_dir(key, dir)
      d = dir.to_s.downcase
      return d if %w[asc desc].include?(d)
      DEFAULT_DIR[key.to_s]
    end

    def key?(key) = OPTIONS.key?(key.to_s)

    def resolve_key(key) = key?(key) ? key.to_s : DEFAULT_KEY

    # Mongo sort spec. Severity is handled by Query via an added rank field
    # ("_sevrank"); every other key maps to its stored field. A stable "_id"
    # tiebreaker (same direction) keeps paged windows from shuffling ties.
    def mongo_doc(key, dir)
      key = resolve_key(key)
      sign = resolve_dir(key, dir) == "asc" ? 1 : -1
      field = key == "severity" ? "_sevrank" : FIELDS[key]
      { field => sign, "_id" => sign }
    end

    # Comparator over two Vulnerability instances for the in-memory fallback.
    def comparator(key, dir)
      key = resolve_key(key)
      sign = resolve_dir(key, dir) == "asc" ? 1 : -1
      lambda do |a, b|
        (sort_value(a, key) <=> sort_value(b, key)) * sign
      end
    end

    def sort_value(vuln, key)
      case key
      when "severity" then SEVERITY_RANK.fetch(vuln.finding["severity"].to_s.downcase, 0)
      when "date"     then vuln.metadata["date"].to_s
      when "status"   then vuln.report["status"].to_s
      when "program"  then vuln.metadata["program"].to_s
      when "name"     then vuln.finding["name"].to_s
      else vuln.metadata["date"].to_s
      end
    end
  end
end
