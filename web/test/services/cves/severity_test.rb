require "test_helper"

class Cves::SeverityTest < ActiveSupport::TestCase
  def score(vec) = Cves::Severity.call([{ "type" => "CVSS_V3", "score" => vec }])

  test "critical vector scores 9.8/critical" do
    r = score("CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H")
    assert_in_delta 9.8, r["severity_score"], 0.05
    assert_equal "critical", r["severity_level"]
  end

  test "medium vector scores in the medium band" do
    r = score("CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:L/I:N/A:N")
    assert r["severity_score"] >= 4.0 && r["severity_score"] < 7.0
    assert_equal "medium", r["severity_level"]
  end

  test "scope-changed vector applies the 1.08 multiplier" do
    r = score("CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:C/C:H/I:H/A:H")
    assert_in_delta 10.0, r["severity_score"], 0.05
    assert_equal "critical", r["severity_level"]
  end

  test "takes the max across multiple entries" do
    r = Cves::Severity.call([
      { "score" => "CVSS:3.1/AV:N/AC:H/PR:L/UI:R/S:U/C:L/I:N/A:N" },
      { "score" => "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H" }
    ])
    assert_in_delta 9.8, r["severity_score"], 0.05
  end

  test "empty or unparseable severity is unknown" do
    assert_equal({ "severity_score" => nil, "severity_level" => "unknown" }, Cves::Severity.call([]))
    assert_equal "unknown", Cves::Severity.call([{ "score" => "not-a-vector" }])["severity_level"]
  end
end
