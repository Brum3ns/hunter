# View-only formatting for the CVE department. Keeps ERB thin. Methods are
# regular instance methods (mixed into the view / ActionView::TestCase).
module CvesHelper
  # First CVSS vector/score string in the OSV `severity` array, or nil.
  def cve_cvss_score(severity)
    entry = Array(severity).find { |s| s.to_h["type"].to_s.start_with?("CVSS") }
    entry && entry.to_h["score"].presence
  end

  # Short YYYY-MM-DD date. Accepts a Time or an ISO-8601 string; "—" when blank.
  def cve_short_date(value)
    return "—" if value.blank?
    time = value.is_a?(Time) ? value : (Time.iso8601(value.to_s) rescue nil)
    time ? time.strftime("%Y-%m-%d") : "—"
  end

  # Human label for an OSV reference type (FIX, ADVISORY, REPORT, WEB, PACKAGE).
  def cve_reference_label(type)
    type.presence ? type.to_s.capitalize : "Reference"
  end
end
