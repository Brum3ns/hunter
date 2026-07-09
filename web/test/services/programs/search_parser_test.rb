require "test_helper"

class Programs::SearchParserTest < ActiveSupport::TestCase
  test "splits free text from a dork term" do
    r = Programs::SearchParser.call("acme asset:example.com")
    assert_equal "acme", r.free_text
    assert_equal({ "$or" => [
      { "scope.asset" => { "$regex" => "example\\.com", "$options" => "i" } },
      { "outofscope.asset" => { "$regex" => "example\\.com", "$options" => "i" } }
    ] }, r.expression.to_mongo)
  end

  test "AND binds tighter than OR" do
    r = Programs::SearchParser.call("bounty:yes AND platform:h1 OR platform:bc")
    assert_instance_of Programs::DorkExpression::Or, r.expression
  end

  test "plain prose with lowercase or stays free text" do
    r = Programs::SearchParser.call("cats or dogs")
    assert_nil r.expression
    assert_equal "cats or dogs", r.free_text
  end
end
