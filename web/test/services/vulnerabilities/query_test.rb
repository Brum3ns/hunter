require "test_helper"

class Vulnerabilities::QueryTest < ActiveSupport::TestCase
  Q = Vulnerabilities::Query

  # --- match doc (pure, no Mongo) ---------------------------------------
  test "match doc combines facets, date range, free text and dork" do
    expr = Vulnerabilities::SearchParser.call("tool:nuclei").expression
    q = Q.new({ severity: ["critical", "high"], date_from: "2026-01-01",
                q: "login", dork_expression: expr }.with_indifferent_access)
    doc = q.send(:match_doc)
    assert_equal({ "$in" => ["critical", "high"] }, doc["finding.severity"])
    assert_equal({ "$gte" => "2026-01-01" }, doc["metadata.date"])
    assert doc["$and"].any? { |c| c["metadata.tool"] }, "dork clause present"
    assert doc["$or"].present?, "free-text $or present"
  end

  test "match doc for a dimension can exclude that dimension for facet counts" do
    q = Q.new({ severity: ["critical"], tool: ["nuclei"] }.with_indifferent_access)
    doc = q.send(:match_doc, except: "severity")
    assert_nil doc["finding.severity"], "own dimension excluded"
    assert_equal({ "$in" => ["nuclei"] }, doc["metadata.tool"])
  end

  # --- fallback path (no live Mongo) ------------------------------------
  test "falls back to in-memory Filter + Sort when mongo is unusable" do
    vulns = [
      Vulnerability.new("finding" => { "severity" => "low", "name" => "a" }, "metadata" => { "date" => "2026-01-01" }, "id" => "a"),
      Vulnerability.new("finding" => { "severity" => "critical", "name" => "b" }, "metadata" => { "date" => "2026-06-01" }, "id" => "b")
    ]
    result = nil
    # mongo_usable? / fallback_source are private INSTANCE methods, so stub them
    # on an instance (stub_methods redefines singleton methods on its target).
    q = Q.new({ sort: "severity" }.with_indifferent_access)
    stub_methods(q, mongo_usable?: false, fallback_source: vulns) do
      result = q.call
    end
    assert_equal ["b", "a"], result.findings.map(&:id)
    assert_equal 2, result.total
    assert_equal 1, result.facets["severity"]["critical"]
  end
end
