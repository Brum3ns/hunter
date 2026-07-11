require "test_helper"

class Vulnerabilities::StatisticsTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }

  DASHBOARD = {
    total: 12,
    summary: { created: 12, reported: 4, false_positives: 2 },
    new_7d: 5,
    new_30d: 9,
    severity: [
      { key: "critical", label: "Critical", count: 3 },
      { key: "high",     label: "High",     count: 5 },
      { key: "medium",   label: "Medium",   count: 2 },
      { key: "low",      label: "Low",      count: 1 },
      { key: "info",     label: "Info",     count: 1 }
    ],
    status: [
      { key: "new",            label: "New",            count: 6 },
      { key: "triage",         label: "Triage",         count: 3 },
      { key: "reported",       label: "Reported",       count: 2 },
      { key: "close",          label: "Close",          count: 1 },
      { key: "false_positive", label: "False positive", count: 0 }
    ],
    methods: [{ key: "get", label: "GET", count: 8 }, { key: "post", label: "POST", count: 4 }],
    confidence: [{ key: "high", label: "High", count: 6 }],
    submitted: [
      { key: "submitted", label: "Submitted", count: 4, color: "text-emerald-500" },
      { key: "not_submitted", label: "Not submitted", count: 8, color: "text-zinc-400" }
    ],
    types: [{ key: "http", label: "http", count: 9 }],
    tools: [{ key: "nuclei", label: "nuclei", count: 9 }],
    programs: [{ key: "acme", label: "acme", count: 7 }],
    cwes: [{ key: "CWE-79", label: "CWE-79", count: 5 }],
    hosts: [{ key: "app.acme.com", label: "app.acme.com", count: 6 }],
    tags: [{ key: "xss", label: "xss", count: 4 }],
    timeline: [
      { key: "2026-06", label: "Jun", year: 2026, count: 5 },
      { key: "2026-07", label: "Jul", year: 2026, count: 7 }
    ],
    daily: [
      { key: "2026-07-09", label: "9 Jul", count: 2 },
      { key: "2026-07-10", label: "10 Jul", count: 3 }
    ]
  }.freeze

  test "redirects an unauthenticated visitor to sign in" do
    get vulnerabilities_statistics_path
    assert_redirected_to new_session_path
  end

  test "renders the statistics page with the active Statistics tab and every panel" do
    sign_in_as(@user)

    stub_methods(Vulnerabilities::Stats, dashboard: -> { DASHBOARD }) do
      get vulnerabilities_statistics_path
    end

    assert_response :success
    # Tab strip: Statistics active, Vulnerabilities not.
    assert_select "a[href=?][aria-current=page]", vulnerabilities_statistics_path, text: "Statistics"
    assert_select "a[href=?]:not([aria-current])", vulnerabilities_root_path, text: "Vulnerabilities"
    # Headline metrics.
    assert_select "p", text: "New this week"
    assert_select "p", text: "Critical & high"
    # Severity donut arcs (track ring + one per non-zero bucket).
    assert_select "svg circle", minimum: 2
    # Panels for the new dimensions.
    assert_select "h2", text: "Top CWEs"
    assert_select "h2", text: "Top tags"
    assert_select "h2", text: "Top hosts"
    assert_select "h2", text: "HTTP methods"
    assert_select "h2", text: "New findings"
    # Monthly and daily bars carry their tooltips.
    assert_select "div[title=?]", "7 in Jul 2026"
    assert_select "div[title=?]", "3 on 10 Jul"
  end
end
