require "test_helper"

class Vulnerabilities::OverviewTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }

  Query = Vulnerabilities::Query
  Stats = Vulnerabilities::Stats

  EMPTY_FACETS = { "severity" => {}, "status" => {}, "tool" => {}, "type" => {}, "program" => {} }.freeze

  def result(findings: [], total: 0, facets: EMPTY_FACETS)
    Query::Result.new(
      findings: findings, total: total, facets: facets,
      page: 1, per_page: 50, has_next: false, sort_key: "date", sort_dir: "desc"
    )
  end

  def stub_page(res, summary: { created: 0, reported: 0, false_positives: 0 })
    stub_methods(Query, call: ->(*) { res }) do
      stub_methods(Stats, summary: summary) do
        yield
      end
    end
  end

  test "redirects an unauthenticated visitor to sign in" do
    get vulnerabilities_root_path
    assert_redirected_to new_session_path
  end

  test "renders the findings table and stats for an authenticated user" do
    sign_in_as(@user)
    finding = Vulnerability.new("id" => "1", "finding" => { "name" => "XSS", "severity" => "high" }, "report" => { "status" => "new" })

    stub_page(result(findings: [finding], total: 1), summary: { created: 1, reported: 0, false_positives: 0 }) do
      get vulnerabilities_root_path
      assert_response :success
      assert_select "table"
      assert_select "a[href=?][aria-current=page]", vulnerabilities_root_path
    end
  end

  test "applies a dork query and multi-select facets through Query" do
    sign_in_as(@user)
    captured = nil
    stub_methods(Query, call: ->(params) { captured = params; result }) do
      stub_methods(Stats, summary: { created: 0, reported: 0, false_positives: 0 }) do
        get vulnerabilities_root_path, params: { q: "severity:high login", severity: ["high", "critical"], sort: "date" }
      end
    end
    assert_response :success
    assert_equal ["high", "critical"], captured[:severity]
    assert_equal "login", captured[:q], "dork stripped, free text kept"
    assert captured[:dork_expression], "parsed expression forwarded"
  end

  test "renders an empty state when there are no findings" do
    sign_in_as(@user)
    stub_page(result) do
      get vulnerabilities_root_path
      assert_response :success
    end
  end

  test "renders facet sidebar with counts and active chips with remove links" do
    sign_in_as(@user)
    facets = { "severity" => { "critical" => 12, "high" => 40 }, "status" => {}, "tool" => { "nuclei" => 7 }, "type" => {}, "program" => {} }
    stub_page(result(facets: facets)) do
      get vulnerabilities_root_path, params: { severity: ["critical"] }
    end
    assert_response :success
    assert_select "input[type=checkbox][name='severity[]'][value=critical][checked=checked]"
    assert_select "aside", text: /critical/i
    assert_select "aside", text: /12/
    assert_select "a", text: /severity: Critical/i
    # Sort is via clickable column headers now (no sort dropdown).
    assert_select "th a", text: /Severity/
    assert_select "input[type=hidden][name=sort]"
  end
end
