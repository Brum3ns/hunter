require "test_helper"

class Vulnerabilities::FilterTest < ActiveSupport::TestCase
  F = Vulnerabilities::Filter

  def v(sev:, status: "new", tool: "nuclei", type: "http", program: "Acme", name: "n", host: "h.example.com", date: "2026-06-01", tags: [])
    Vulnerability.new(
      "finding"  => { "severity" => sev, "type" => type, "name" => name, "tags" => tags },
      "report"   => { "status" => status },
      "metadata" => { "tool" => tool, "program" => program, "date" => date },
      "target"   => { "host" => host }, "id" => "#{sev}-#{name}"
    )
  end

  def setup
    @all = [
      v(sev: "critical", tool: "nuclei", program: "Acme"),
      v(sev: "high",     tool: "nikto",  program: "Acme"),
      v(sev: "low",      tool: "nuclei", program: "Beta", name: "sqli")
    ]
  end

  test "severity facet param keeps only matching rows" do
    out = F.call(@all, { severity: ["critical"] }.with_indifferent_access)
    assert_equal ["critical-n"], out.map(&:id)
  end

  test "multi-value facet is an OR within the dimension" do
    out = F.call(@all, { severity: ["critical", "high"] }.with_indifferent_access)
    assert_equal 2, out.size
  end

  test "free text matches name or host" do
    out = F.call(@all, { q: "sqli" }.with_indifferent_access)
    assert_equal ["low-sqli"], out.map(&:id)
  end

  test "dork expression is applied" do
    expr = Vulnerabilities::SearchParser.call("tool:nuclei").expression
    out = F.call(@all, { dork_expression: expr }.with_indifferent_access)
    assert_equal ["critical-n", "low-sqli"], out.map(&:id)
  end

  test "date range is inclusive" do
    old = v(sev: "low", date: "2026-01-01", name: "old")
    out = F.call(@all + [old], { date_from: "2026-05-01" }.with_indifferent_access)
    assert_not_includes out.map(&:id), "low-old"
  end

  test "facets count with other filters applied but not their own dimension" do
    facets = F.facets(@all, { severity: ["critical"] }.with_indifferent_access)
    assert_equal({ "critical" => 1, "high" => 1, "low" => 1 }, facets["severity"])
    assert_equal({ "nuclei" => 1 }, facets["tool"])
  end
end
