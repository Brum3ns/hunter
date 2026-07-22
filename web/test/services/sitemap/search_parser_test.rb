require "test_helper"

class Sitemap::SearchParserTest < ActiveSupport::TestCase
  Term = Sitemap::DorkExpression::Term
  And_ = Sitemap::DorkExpression::And
  Or_  = Sitemap::DorkExpression::Or

  def parse(query) = Sitemap::SearchParser.call(query)

  test "plain text has no expression" do
    result = parse("admin login")
    assert_equal "admin login", result.free_text
    assert_nil result.expression
  end

  test "free text and quoted dorks can mix" do
    result = parse('admin content_type:"application/json"')
    assert_equal "admin", result.free_text
    assert_equal Term.new(key: "content_type", op: nil, value: "application/json"), result.expression
  end

  test "adjacent terms imply AND and capture comparisons" do
    result = parse("method:POST status:>=400")
    assert_equal And_.new(children: [
      Term.new(key: "method", op: nil, value: "POST"),
      Term.new(key: "status", op: ">=", value: "400")
    ]), result.expression
  end

  test "AND binds tighter than OR and parentheses override it" do
    result = parse("root:yes OR method:POST AND status:500")
    assert_instance_of Or_, result.expression
    assert_instance_of And_, result.expression.children.last

    grouped = parse("(root:yes OR method:POST) AND status:500")
    assert_instance_of And_, grouped.expression
    assert_instance_of Or_, grouped.expression.children.first
  end

  test "symbolic boolean operators are accepted" do
    result = parse("method:POST && (status:200 || status:201)")
    assert_instance_of And_, result.expression
    assert_instance_of Or_, result.expression.children.last
  end

  test "unknown keys and orphan operators remain free text" do
    result = parse("cats or dogs unknown:value")
    assert_equal "cats or dogs unknown:value", result.free_text
    assert_nil result.expression
  end

  test "every public key is recognized" do
    %w[
      host origin program path url content_type method scheme
      port status length has_query root seen
    ].each do |key|
      assert_instance_of Term, parse("#{key}:value").expression, key
    end
  end
end
