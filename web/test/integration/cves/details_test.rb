require "test_helper"

class Cves::DetailsTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }

  Source = Cves::MongoSource

  DOC = {
    "id" => "CVE-2024-1234", "osv_id" => "GHSA-xxxx",
    "aliases" => ["CVE-2024-1234", "GHSA-xxxx"],
    "summary" => "XSS in foo", "details" => "long **markdown** body",
    "published" => "2024-01-02T00:00:00Z", "modified" => "2024-01-05T00:00:00Z",
    "severity" => [{ "type" => "CVSS_V3", "score" => "CVSS:3.1/AV:N" }],
    "cwe_ids" => ["CWE-79"], "ecosystems" => ["npm"], "has_fix" => true,
    "affected" => [{ "ecosystem" => "npm", "package" => "foo", "purl" => "pkg:npm/foo",
                     "versions" => ["1.0.0"], "ranges" => [{ "type" => "SEMVER", "introduced" => "0", "fixed" => "1.2.3" }] }],
    "references" => [{ "type" => "FIX", "url" => "https://github.com/org/foo/commit/def456" }],
    "chain" => { "issue_urls" => ["https://github.com/org/foo/issues/12"],
                 "fix_commits" => ["https://github.com/org/foo/commit/def456"],
                 "advisory_urls" => ["https://github.com/advisories/GHSA-xxxx"],
                 "fixed_versions" => [{ "ecosystem" => "npm", "package" => "foo", "version" => "1.2.3" }],
                 "git_ranges" => [] }
  }.freeze

  test "redirects an unauthenticated visitor to sign in" do
    get cves_detail_path("CVE-2024-1234")
    assert_redirected_to new_session_path
  end

  test "renders the drawer with the chain and affected data for a found CVE" do
    sign_in_as(@user)
    stub_methods(Source, find: DOC) do
      get cves_detail_path("CVE-2024-1234")
      assert_response :success
      assert_select "turbo-frame#cve_panel"
      assert_select "a[href=?]", "https://github.com/org/foo/commit/def456"
      assert_select "a[href=?]", "https://github.com/org/foo/issues/12"
      assert_select "body", text: /CVE-2024-1234/
      assert_select "body", text: /pkg:npm\/foo/
    end
  end

  test "returns not_found for a missing CVE" do
    sign_in_as(@user)
    stub_methods(Source, find: nil) do
      get cves_detail_path("CVE-0000-0000")
      assert_response :not_found
    end
  end
end
