require "test_helper"

class Vulnerabilities::SearchParserTest < ActiveSupport::TestCase
  SP = Vulnerabilities::SearchParser
  DE = Vulnerabilities::DorkExpression

  test "plain words are free text with no expression" do
    r = SP.call("header fuzzer")
    assert_equal "header fuzzer", r.free_text
    assert_nil r.expression
  end

  test "a single dork becomes a Term and leaves free text behind" do
    r = SP.call("header severity:high")
    assert_equal "header", r.free_text
    assert_instance_of DE::Term, r.expression
    assert_equal ["severity", "high"], [r.expression.key, r.expression.value]
  end

  test "range operator is captured" do
    r = SP.call("date:>=2026-06-01")
    assert_equal ">=", r.expression.op
    assert_equal "2026-06-01", r.expression.value
  end

  test "AND binds tighter than OR" do
    r = SP.call("severity:high AND tool:nuclei OR tool:nikto")
    assert_instance_of DE::Or, r.expression
    assert_instance_of DE::And, r.expression.children.first
  end

  test "adjacent terms imply AND" do
    r = SP.call("severity:high tool:nuclei")
    assert_instance_of DE::And, r.expression
    assert_equal 2, r.expression.children.size
  end

  test "quoted values keep spaces" do
    r = SP.call(%(program:"Mirakl Helpdesk"))
    assert_equal "Mirakl Helpdesk", r.expression.value
  end

  test "unknown keys stay free text" do
    r = SP.call("foo:bar severity:low")
    assert_includes r.free_text, "foo:bar"
    assert_instance_of DE::Term, r.expression
  end

  test "prose with or is not parsed as an operator" do
    r = SP.call("cats or dogs")
    assert_equal "cats or dogs", r.free_text
    assert_nil r.expression
  end

  test "empty input yields empty free text and nil expression" do
    r = SP.call("")
    assert_equal "", r.free_text
    assert_nil r.expression
  end
end
