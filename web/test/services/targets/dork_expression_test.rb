require "test_helper"

class Targets::DorkExpressionTest < ActiveSupport::TestCase
  include Targets::DorkExpression

  test "a text key becomes a case-insensitive substring regex" do
    assert_equal(
      { "target.host" => { "$regex" => "example\\.com", "$options" => "i" } },
      Term.new(key: "host", op: nil, value: "example.com").to_mongo
    )
  end

  test "a * in a text value becomes an anchored wildcard" do
    assert_equal(
      { "target.host" => { "$regex" => "\\A.*\\.example\\.com\\z", "$options" => "i" } },
      Term.new(key: "host", op: nil, value: "*.example.com").to_mongo
    )
  end

  test "the tech array field matches any element" do
    assert_equal(
      { "tech" => { "$regex" => "nginx", "$options" => "i" } },
      Term.new(key: "tech", op: nil, value: "nginx").to_mongo
    )
  end

  test "method is an anchored exact match" do
    assert_equal(
      { "target.method" => { "$regex" => "\\AGET\\z", "$options" => "i" } },
      Term.new(key: "method", op: nil, value: "GET").to_mongo
    )
  end

  test "status is numeric equality by default" do
    assert_equal({ "http.status_code" => 200 }, Term.new(key: "status", op: nil, value: "200").to_mongo)
  end

  test "status honors range operators" do
    assert_equal({ "http.status_code" => { "$gte" => 500 } }, Term.new(key: "status", op: ">=", value: "500").to_mongo)
  end

  test "And and Or wrap their children" do
    a = Term.new(key: "status", op: nil, value: "200")
    b = Term.new(key: "host", op: nil, value: "a.com")
    assert_equal({ "$and" => [a.to_mongo, b.to_mongo] }, And.new(children: [a, b]).to_mongo)
    assert_equal({ "$or" => [a.to_mongo, b.to_mongo] }, Or.new(children: [a, b]).to_mongo)
  end

  test "a single-child And collapses to that child" do
    a = Term.new(key: "status", op: nil, value: "200")
    assert_equal a.to_mongo, And.new(children: [a]).to_mongo
  end
end
