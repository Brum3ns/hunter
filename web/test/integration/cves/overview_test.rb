require "test_helper"

class Cves::OverviewTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }

  Source = Cves::MongoSource

  def cve_doc(id, **over)
    { "id" => id, "summary" => "XSS in foo", "ecosystems" => ["npm"],
      "has_fix" => true, "modified" => "2024-01-05T00:00:00Z",
      "severity" => [{ "type" => "CVSS_V3", "score" => "CVSS:3.1/AV:N" }] }.merge(over.transform_keys(&:to_s))
  end

  def stub_index(docs: [], total: 0, facets: [{ "ecosystem" => "npm", "count" => 3 }])
    stub_methods(Source, all: docs, count: total, ecosystem_facets: facets) { yield }
  end

  test "redirects an unauthenticated visitor to sign in" do
    get cves_root_path
    assert_redirected_to new_session_path
  end

  test "renders the table, facets, and active tab for a signed-in user" do
    sign_in_as(@user)
    stub_index(docs: [cve_doc("CVE-2024-1234")], total: 1) do
      get cves_root_path
      assert_response :success
      assert_select "table"
      assert_select "td", text: /CVE-2024-1234/
      assert_select "a[href=?][aria-current=page]", cves_root_path
      assert_select "turbo-frame#cve_panel"
    end
  end

  test "passes filters, search, and page through to MongoSource.all" do
    sign_in_as(@user)
    captured = nil
    capture = ->(filters:, search:, page:, limit:) { captured = { filters:, search:, page:, limit: }; [] }
    stub_methods(Source, all: capture, count: 0, ecosystem_facets: []) do
      get cves_root_path, params: {
        q: "xss", ecosystem: "npm", package: "foo", has_fix: "true",
        published_after: "2026-01-01", modified_after: "2026-02-01", page: "2"
      }
    end
    assert_equal "xss", captured[:search]
    assert_equal "npm", captured[:filters]["ecosystem"]
    assert_equal "foo", captured[:filters]["package"]
    assert_equal "true", captured[:filters]["has_fix"]
    assert_equal "2026-01-01", captured[:filters]["published_after"]
    assert_equal "2026-02-01", captured[:filters]["modified_after"]
    assert_equal 2, captured[:page]
  end

  test "renders an empty state when there are no CVEs" do
    sign_in_as(@user)
    stub_index(docs: [], total: 0) do
      get cves_root_path
      assert_response :success
      assert_select "td", text: /No CVEs/
    end
  end
end
