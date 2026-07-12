require "test_helper"

class CveTest < ActiveSupport::TestCase
  DOC = {
    "id" => "CVE-2024-1234", "osv_id" => "GHSA-xxxx",
    "aliases" => ["CVE-2024-1234", "GHSA-xxxx"],
    "summary" => "XSS in foo", "details" => "long details",
    "severity" => [{ "type" => "CVSS_V3", "score" => "CVSS:3.1/AV:N" }],
    "cwe_ids" => ["CWE-79"], "ecosystems" => ["npm"],
    "affected" => [{ "ecosystem" => "npm", "package" => "foo" }],
    "references" => [{ "type" => "FIX", "url" => "https://x/commit/abc" }],
    "has_fix" => true,
    "chain" => { "fix_commits" => ["https://x/commit/abc"] }
  }.freeze

  test "exposes normalized sections and defaults missing ones" do
    cve = Cve.new(DOC)
    assert_equal "CVE-2024-1234", cve.id
    assert_equal "GHSA-xxxx", cve.osv_id
    assert_equal ["npm"], cve.ecosystems
    assert_equal true, cve.has_fix
    assert_equal ["https://x/commit/abc"], cve.chain["fix_commits"]
    assert_equal({}, Cve.new({}).chain)
    assert_equal [], Cve.new({}).affected
  end

  test "as_json returns the full attributes with string keys" do
    assert_equal DOC, Cve.new(DOC).as_json
    assert_equal DOC, Cve.new(DOC.transform_keys(&:to_sym)).as_json
  end
end
