module Cves
  # Turns a raw OSV record (parsed JSON hash) into Hunter's normalized `cves`
  # document, or nil when the record carries no CVE id (we only track CVEs).
  # Pure — no I/O, no timestamps of our own (first_seen_at/last_synced_at are
  # stamped by MongoSource#upsert).
  module Normalizer
    module_function

    def call(raw)
      raw = raw.to_h.transform_keys(&:to_s)
      cve = Array(raw["aliases"]).find { |a| a.to_s.start_with?("CVE-") }
      return nil unless cve

      affected = normalize_affected(raw["affected"])
      references = Array(raw["references"]).map { |r| r.to_h.transform_keys(&:to_s).slice("type", "url") }
      severity = Array(raw["severity"])
      ecosystems = affected.map { |a| a["ecosystem"] }.compact.uniq
      derived_severity = Cves::Severity.call(severity)
      vendors = Cves::Vendors.call(affected)

      {
        "id" => cve,
        "osv_id" => raw["id"],
        "aliases" => Array(raw["aliases"]),
        "summary" => raw["summary"].to_s,
        "details" => raw["details"].to_s,
        "published" => parse_time(raw["published"]),
        "modified" => parse_time(raw["modified"]),
        "withdrawn" => parse_time(raw["withdrawn"]),
        "severity" => severity,
        "severity_score" => derived_severity["severity_score"],
        "severity_level" => derived_severity["severity_level"],
        "cwe_ids" => cwe_ids(raw, affected_raw: raw["affected"]),
        "ecosystems" => ecosystems,
        "languages" => Cves::Languages.call(ecosystems),
        "vendors" => vendors,
        "tags" => Cves::Tagger.call(ecosystems: ecosystems, affected: affected, vendors: vendors),
        "affected" => affected,
        "references" => references,
        "has_fix" => has_fix?(references, affected),
        "chain" => chain(references, affected)
      }
    end

    def normalize_affected(affected)
      Array(affected).map do |entry|
        entry = entry.to_h.transform_keys(&:to_s)
        pkg = (entry["package"] || {}).to_h.transform_keys(&:to_s)
        {
          "ecosystem" => pkg["ecosystem"],
          "package" => pkg["name"],
          "purl" => pkg["purl"],
          "versions" => Array(entry["versions"]),
          "ranges" => normalize_ranges(entry["ranges"])
        }
      end
    end
    private_class_method :normalize_affected

    def normalize_ranges(ranges)
      Array(ranges).map do |range|
        range = range.to_h.transform_keys(&:to_s)
        events = Array(range["events"]).map { |e| e.to_h.transform_keys(&:to_s) }
        out = {
          "type" => range["type"],
          "introduced" => events.filter_map { |e| e["introduced"] }.first,
          "fixed" => events.filter_map { |e| e["fixed"] }.first
        }
        out["repo"] = range["repo"] if range["repo"]
        out
      end
    end
    private_class_method :normalize_ranges

    def cwe_ids(raw, affected_raw:)
      top = Array(raw.dig("database_specific", "cwe_ids"))
      nested = Array(affected_raw).flat_map { |a| Array(a.to_h.transform_keys(&:to_s).dig("database_specific", "cwe_ids")) }
      (top + nested).uniq
    end
    private_class_method :cwe_ids

    def has_fix?(references, affected)
      references.any? { |r| r["type"] == "FIX" } ||
        affected.any? { |a| a["ranges"].any? { |r| r["fixed"].present? } }
    end
    private_class_method :has_fix?

    def chain(references, affected)
      by_type = ->(type) { references.select { |r| r["type"] == type }.map { |r| r["url"] } }
      fixed_versions = affected.flat_map do |a|
        a["ranges"].select { |r| r["type"] != "GIT" && r["fixed"].present? }
                   .map { |r| { "ecosystem" => a["ecosystem"], "package" => a["package"], "version" => r["fixed"] } }
      end
      git_ranges = affected.flat_map do |a|
        a["ranges"].select { |r| r["type"] == "GIT" }
                   .map { |r| { "repo" => r["repo"], "introduced" => r["introduced"], "fixed" => r["fixed"] } }
      end
      {
        "issue_urls" => by_type.call("REPORT"),
        "fix_commits" => by_type.call("FIX"),
        "advisory_urls" => by_type.call("ADVISORY"),
        "fixed_versions" => fixed_versions,
        "git_ranges" => git_ranges
      }
    end
    private_class_method :chain

    def parse_time(value)
      return nil if value.blank?
      Time.iso8601(value.to_s).utc
    rescue ArgumentError
      nil
    end
    private_class_method :parse_time
  end
end
