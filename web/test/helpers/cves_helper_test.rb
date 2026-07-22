require "test_helper"

class CvesHelperTest < ActionView::TestCase
  test "cve_cvss_score pulls the score from a CVSS severity entry" do
    severity = [{ "type" => "CVSS_V3", "score" => "CVSS:3.1/AV:N/AC:L" }]
    assert_equal "CVSS:3.1/AV:N/AC:L", cve_cvss_score(severity)
  end

  test "cve_cvss_score returns nil when severity is empty or absent" do
    assert_nil cve_cvss_score([])
    assert_nil cve_cvss_score(nil)
  end

  test "cve_short_date formats a Time and passes through blanks" do
    assert_equal "2024-01-05", cve_short_date(Time.utc(2024, 1, 5, 12, 0, 0))
    assert_equal "—", cve_short_date(nil)
    assert_equal "2024-01-05", cve_short_date("2024-01-05T12:00:00Z")
  end

  test "cve_reference_label humanizes a reference type" do
    assert_equal "Fix", cve_reference_label("FIX")
    assert_equal "Advisory", cve_reference_label("ADVISORY")
    assert_equal "Reference", cve_reference_label(nil)
  end
end
