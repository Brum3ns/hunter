require "test_helper"

class Cves::NormalizerTest < ActiveSupport::TestCase
  RAW = {
    "id" => "GHSA-xxxx-yyyy-zzzz",
    "aliases" => ["CVE-2024-1234", "GHSA-xxxx-yyyy-zzzz"],
    "summary" => "XSS in foo", "details" => "markdown body",
    "published" => "2024-01-02T00:00:00Z", "modified" => "2024-01-05T00:00:00Z",
    "severity" => [{ "type" => "CVSS_V3", "score" => "CVSS:3.1/AV:N" }],
    "database_specific" => { "cwe_ids" => ["CWE-79"] },
    "affected" => [{
      "package" => { "ecosystem" => "npm", "name" => "foo", "purl" => "pkg:npm/foo" },
      "versions" => ["1.0.0", "1.1.0"],
      "database_specific" => { "cwe_ids" => ["CWE-80"] },
      "ranges" => [
        { "type" => "SEMVER", "events" => [{ "introduced" => "0" }, { "fixed" => "1.2.3" }] },
        { "type" => "GIT", "repo" => "https://github.com/org/foo",
          "events" => [{ "introduced" => "abc123" }, { "fixed" => "def456" }] }
      ]
    }],
    "references" => [
      { "type" => "ADVISORY", "url" => "https://github.com/advisories/GHSA-xxxx-yyyy-zzzz" },
      { "type" => "FIX", "url" => "https://github.com/org/foo/commit/def456" },
      { "type" => "REPORT", "url" => "https://github.com/org/foo/issues/12" },
      { "type" => "WEB", "url" => "https://example.com" }
    ]
  }.freeze

  test "returns nil when there is no CVE alias" do
    assert_nil Cves::Normalizer.call(RAW.merge("aliases" => ["GHSA-only"]))
    assert_nil Cves::Normalizer.call(RAW.merge("aliases" => nil))
  end

  test "keys on the CVE alias and keeps the OSV id" do
    doc = Cves::Normalizer.call(RAW)
    assert_equal "CVE-2024-1234", doc["id"]
    assert_equal "GHSA-xxxx-yyyy-zzzz", doc["osv_id"]
    assert_equal RAW["aliases"], doc["aliases"]
  end

  test "parses timestamps to UTC Time and passes severity through" do
    doc = Cves::Normalizer.call(RAW)
    assert_equal Time.utc(2024, 1, 2), doc["published"]
    assert_equal Time.utc(2024, 1, 5), doc["modified"]
    assert_nil doc["withdrawn"]
    assert_equal "CVSS_V3", doc["severity"].first["type"]
  end

  test "gathers cwe ids and ecosystems uniquely" do
    doc = Cves::Normalizer.call(RAW)
    assert_equal %w[CWE-79 CWE-80], doc["cwe_ids"].sort
    assert_equal ["npm"], doc["ecosystems"]
  end

  test "flattens affected packages and ranges" do
    aff = Cves::Normalizer.call(RAW)["affected"].first
    assert_equal "npm", aff["ecosystem"]
    assert_equal "foo", aff["package"]
    assert_equal "pkg:npm/foo", aff["purl"]
    assert_equal ["1.0.0", "1.1.0"], aff["versions"]
    semver = aff["ranges"].find { |r| r["type"] == "SEMVER" }
    git    = aff["ranges"].find { |r| r["type"] == "GIT" }
    assert_equal "1.2.3", semver["fixed"]
    assert_equal "abc123", git["introduced"]
    assert_equal "https://github.com/org/foo", git["repo"]
  end

  test "extracts the CVE to issue to fix chain" do
    chain = Cves::Normalizer.call(RAW)["chain"]
    assert_equal ["https://github.com/org/foo/commit/def456"], chain["fix_commits"]
    assert_equal ["https://github.com/org/foo/issues/12"], chain["issue_urls"]
    assert_equal ["https://github.com/advisories/GHSA-xxxx-yyyy-zzzz"], chain["advisory_urls"]
    assert_equal([{ "ecosystem" => "npm", "package" => "foo", "version" => "1.2.3" }], chain["fixed_versions"])
    assert_equal([{ "repo" => "https://github.com/org/foo", "introduced" => "abc123", "fixed" => "def456" }], chain["git_ranges"])
  end

  test "derives has_fix true from a fix reference or a fixed range" do
    assert_equal true, Cves::Normalizer.call(RAW)["has_fix"]
    no_fix = RAW.merge(
      "references" => [{ "type" => "WEB", "url" => "https://x" }],
      "affected" => [{ "package" => { "ecosystem" => "npm", "name" => "foo" },
                       "ranges" => [{ "type" => "SEMVER", "events" => [{ "introduced" => "0" }] }] }]
    )
    assert_equal false, Cves::Normalizer.call(no_fix)["has_fix"]
  end

  test "handles a withdrawn record and missing optional fields" do
    doc = Cves::Normalizer.call(RAW.merge("withdrawn" => "2024-02-01T00:00:00Z", "details" => nil))
    assert_equal Time.utc(2024, 2, 1), doc["withdrawn"]
    assert_equal "", doc["details"]
  end
end
