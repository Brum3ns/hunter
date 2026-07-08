require "test_helper"

class Vulnerabilities::DorkExpressionTest < ActiveSupport::TestCase
  DE = Vulnerabilities::DorkExpression

  def vuln(overrides = {})
    base = {
      "metadata" => { "program" => "Mirakl Helpdesk", "asset" => "helpdesk", "tool" => "nuclei", "date" => "2026-06-30" },
      "report"   => { "status" => "new", "submitted" => false },
      "finding"  => { "name" => "Header Fuzzer", "type" => "http", "cwe" => "CWE-20", "severity" => "low", "tags" => ["fuzz", "headers"] },
      "target"   => { "host" => "helpdesk.mirakl.net", "url" => "https://helpdesk.mirakl.net", "ip" => "216.198.53.11", "port" => "443", "method" => "GET" },
      "poc"      => { "confidence" => "high" }
    }
    Vulnerability.new(base.deep_merge(overrides))
  end

  # key, op, value, mongo clause, [vuln overrides that MATCH], [vuln overrides that DON'T]
  CASES = [
    ["severity", nil, "LOW",       { "finding.severity" => { "$regex" => "\\Alow\\z", "$options" => "i" } }, {}, { "finding" => { "severity" => "high" } }],
    ["status",   nil, "new",       { "report.status"    => { "$regex" => "\\Anew\\z", "$options" => "i" } }, {}, { "report" => { "status" => "close" } }],
    ["tool",     nil, "nuclei",    { "metadata.tool"    => { "$regex" => "\\Anuclei\\z", "$options" => "i" } }, {}, { "metadata" => { "tool" => "nikto" } }],
    ["type",     nil, "http",      { "finding.type"     => { "$regex" => "\\Ahttp\\z", "$options" => "i" } }, {}, { "finding" => { "type" => "dns" } }],
    ["cwe",      nil, "cwe-20",    { "finding.cwe"      => { "$regex" => "\\Acwe\\-20\\z", "$options" => "i" } }, {}, { "finding" => { "cwe" => "CWE-79" } }],
    ["ip",       nil, "216.198.53.11", { "target.ip"    => { "$regex" => "\\A216\\.198\\.53\\.11\\z", "$options" => "i" } }, {}, { "target" => { "ip" => "1.1.1.1" } }],
    ["port",     nil, "443",       { "target.port"      => { "$regex" => "\\A443\\z", "$options" => "i" } }, {}, { "target" => { "port" => "80" } }],
    ["method",   nil, "get",       { "target.method"    => { "$regex" => "\\Aget\\z", "$options" => "i" } }, {}, { "target" => { "method" => "POST" } }],
    ["confidence", nil, "high",    { "poc.confidence"   => { "$regex" => "\\Ahigh\\z", "$options" => "i" } }, {}, { "poc" => { "confidence" => "low" } }],
    ["tag",      nil, "fuzz",      { "finding.tags"     => { "$regex" => "\\Afuzz\\z", "$options" => "i" } }, {}, { "finding" => { "tags" => ["xss"] } }],
    ["program",  nil, "mirakl",    { "metadata.program" => { "$regex" => "mirakl", "$options" => "i" } }, {}, { "metadata" => { "program" => "Acme" } }],
    ["asset",    nil, "help",      { "metadata.asset"   => { "$regex" => "help", "$options" => "i" } }, {}, { "metadata" => { "asset" => "api" } }],
    ["name",     nil, "fuzzer",    { "finding.name"     => { "$regex" => "fuzzer", "$options" => "i" } }, {}, { "finding" => { "name" => "SQLi" } }],
    ["host",     nil, "mirakl.net", { "target.host"     => { "$regex" => "mirakl\\.net", "$options" => "i" } }, {}, { "target" => { "host" => "example.com" } }],
    ["url",      nil, "https",     { "target.url"       => { "$regex" => "https", "$options" => "i" } }, {}, { "target" => { "url" => "" } }],
    ["submitted", nil, "no",       { "report.submitted" => false }, {}, { "report" => { "submitted" => true } }],
    ["date",     ">=", "2026-06-01", { "metadata.date"  => { "$gte" => "2026-06-01" } }, {}, { "metadata" => { "date" => "2026-01-01" } }],
    ["date",     "<=", "2026-06-01", { "metadata.date"  => { "$lte" => "2026-06-01" } }, { "metadata" => { "date" => "2026-05-01" } }, {}]
  ].freeze

  test "each key emits the expected mongo clause" do
    CASES.each do |key, op, value, clause, _match, _no|
      assert_equal clause, DE::Mapper.to_mongo(key, op, value), "to_mongo(#{key})"
    end
  end

  test "evaluate agrees with to_mongo intent for matching and non-matching docs" do
    CASES.each do |key, op, value, _clause, match_over, no_over|
      assert DE::Mapper.evaluate(vuln(match_over), key, op, value), "expected #{key}:#{value} to match"
      assert_not DE::Mapper.evaluate(vuln(no_over), key, op, value), "expected #{key}:#{value} to NOT match"
    end
  end

  test "unknown key returns nil clause and false evaluation" do
    assert_nil DE::Mapper.to_mongo("bogus", nil, "x")
    assert_not DE::Mapper.evaluate(vuln, "bogus", nil, "x")
  end

  test "And/Or compose to_mongo and evaluate" do
    hi  = DE::Term.new(key: "severity", op: nil, value: "low")
    tool = DE::Term.new(key: "tool", op: nil, value: "nuclei")
    andx = DE::And.new(children: [hi, tool])
    assert_equal({ "$and" => [hi.to_mongo, tool.to_mongo] }, andx.to_mongo)
    assert andx.evaluate(vuln)
    orx = DE::Or.new(children: [DE::Term.new(key: "tool", op: nil, value: "nikto"), tool])
    assert orx.evaluate(vuln)
    assert_equal tool.to_mongo, DE::And.new(children: [tool]).to_mongo, "single child unwraps"
  end
end
