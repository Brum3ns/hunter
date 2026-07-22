require "test_helper"

class Targets::SearchParserTest < ActiveSupport::TestCase
  Term = Targets::DorkExpression::Term
  And_ = Targets::DorkExpression::And
  Or_  = Targets::DorkExpression::Or

  def parse(q) = Targets::SearchParser.call(q)

  test "plain words are free text with no expression" do
    r = parse("cloudron dashboard")
    assert_equal "cloudron dashboard", r.free_text
    assert_nil r.expression
  end

  test "a single dork term parses into a Term with no free text" do
    r = parse("host:example.com")
    assert_equal "", r.free_text
    assert_equal Term.new(key: "host", op: nil, value: "example.com"), r.expression
  end

  test "free text and a dork can mix" do
    r = parse("nginx host:example.com")
    assert_equal "nginx", r.free_text
    assert_equal Term.new(key: "host", op: nil, value: "example.com"), r.expression
  end

  test "adjacent terms imply AND" do
    r = parse("host:a.com status:200")
    assert_equal And_.new(children: [
      Term.new(key: "host", op: nil, value: "a.com"),
      Term.new(key: "status", op: nil, value: "200")
    ]), r.expression
  end

  test "explicit OR builds an Or node" do
    r = parse("status:200 or status:301")
    assert_equal Or_.new(children: [
      Term.new(key: "status", op: nil, value: "200"),
      Term.new(key: "status", op: nil, value: "301")
    ]), r.expression
  end

  test "and/or between non-operands stay free text" do
    r = parse("cats or dogs")
    assert_equal "cats or dogs", r.free_text
    assert_nil r.expression
  end

  test "a range operator is captured on the term" do
    assert_equal Term.new(key: "status", op: ">=", value: "500"), parse("status:>=500").expression
  end

  test "a quoted value keeps its spaces" do
    assert_equal Term.new(key: "title", op: nil, value: "not found"), parse('title:"not found"').expression
  end

  test "an unrecognized key falls through to free text" do
    r = parse("foo:bar")
    assert_equal "foo:bar", r.free_text
    assert_nil r.expression
  end
end
