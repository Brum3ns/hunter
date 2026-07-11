require "test_helper"

class Vulnerabilities::StatsTest < ActiveSupport::TestCase
  Stats = Vulnerabilities::Stats

  # count_documents for #summary; aggregate returns a canned $facet document.
  class FakeCollection
    attr_reader :filters, :pipelines

    def initialize(counts: [], facet: {})
      @counts = counts
      @facet = facet
      @filters = []
      @pipelines = []
    end

    def count_documents(filter)
      @filters << filter
      @counts.shift
    end

    def aggregate(pipeline)
      @pipelines << pipeline
      [@facet]
    end
  end

  def with_collection(collection, &block)
    stub_methods(Stats, collection: collection, &block)
  end

  def rows(pairs)
    pairs.map { |id, count| { "_id" => id, "count" => count } }
  end

  # ---- summary (overview cards) ---------------------------------------------

  test "summary maps counts to the created/reported/false-positive cards" do
    collection = FakeCollection.new(counts: [12, 4, 2])

    with_collection(collection) do
      assert_equal({ created: 12, reported: 4, false_positives: 2 }, Stats.summary)
    end

    assert_equal({}, collection.filters[0])
    assert_equal({ "report.status" => { "$in" => %w[reported] } }, collection.filters[1])
  end

  test "summary returns zeros when Mongo is unreachable" do
    stub_methods(Stats, count: ->(*) { raise Mongo::Error.new("down") }) do
      assert_equal({ created: 0, reported: 0, false_positives: 0 }, Stats.summary)
    end
  end

  # ---- transforms -----------------------------------------------------------

  test "ordered_from zero-fills a vocabulary in order and folds unknowns" do
    result = Stats.ordered_from(rows([["HIGH", 5], ["bogus", 3], [nil, 1]]),
                                VulnerabilitiesHelper::SEVERITIES, "info")

    assert_equal %w[critical high medium low info], result.map { |b| b[:key] }
    counts = result.to_h { |b| [b[:key], b[:count]] }
    assert_equal 5, counts["high"], "case-insensitive match"
    assert_equal 4, counts["info"], "unknown (3) + blank (1) fold into info"
  end

  test "top_from ranks busiest first, drops zero/blank ranking, caps at limit" do
    result = Stats.top_from(rows([["acme", 3], ["globex", 7], [nil, 2]]))
    assert_equal %w[globex acme unknown], result.map { |b| b[:label] }
    assert_equal [7, 3, 2], result.map { |b| b[:count] }

    many = Stats.top_from((1..20).map { |i| { "_id" => "t#{i}", "count" => i } })
    assert_equal Vulnerabilities::Stats::TOP_LIMIT, many.length
  end

  test "confidence_from orders high to low and labels the rest unrated" do
    result = Stats.confidence_from(rows([["low", 2], ["high", 5], [nil, 4], ["bogus", 1]]))
    assert_equal %w[high low unrated], result.map { |b| b[:key] }
    assert_equal 5, result.first[:count]
    assert_equal 5, result.last[:count], "nil (4) + bogus (1) fold into unrated"
  end

  test "submitted_from splits true from everything else and sums to total" do
    result = Stats.submitted_from(rows([[true, 3]]), 10)
    assert_equal 3, result.find { |b| b[:key] == "submitted" }[:count]
    assert_equal 7, result.find { |b| b[:key] == "not_submitted" }[:count]
  end

  test "monthly_from zero-fills a trailing window ending this month" do
    this_month = Date.current.strftime("%Y-%m")
    result = Stats.monthly_from(rows([[this_month, 9]]), 6)

    assert_equal 6, result.length
    assert_equal this_month, result.last[:key]
    assert_equal 9, result.last[:count]
    assert_equal 0, result.first[:count]
  end

  test "recent_total sums only buckets within the trailing window" do
    today = Date.current.strftime("%Y-%m-%d")
    old = (Date.current - 40).strftime("%Y-%m-%d")
    assert_equal 5, Stats.recent_total(rows([[today, 5], [old, 99]]), 7)
  end

  # ---- dashboard (single $facet) --------------------------------------------

  FACET = {
    "total"    => [{ "count" => 12 }],
    "severity" => [{ "_id" => "critical", "count" => 3 }, { "_id" => "high", "count" => 5 }],
    "status"   => [{ "_id" => "reported", "count" => 4 }, { "_id" => "false_positive", "count" => 2 }],
    "method"   => [{ "_id" => "get", "count" => 8 }],
    "confidence" => [{ "_id" => "high", "count" => 6 }],
    "submitted"  => [{ "_id" => true, "count" => 4 }],
    "type"     => [{ "_id" => "http", "count" => 9 }],
    "tool"     => [{ "_id" => "nuclei", "count" => 9 }],
    "program"  => [{ "_id" => "acme", "count" => 7 }],
    "cwe"      => [{ "_id" => "CWE-79", "count" => 5 }],
    "host"     => [{ "_id" => "app.acme.com", "count" => 6 }],
    "tags"     => [{ "_id" => "xss", "count" => 4 }],
    "monthly"  => [{ "_id" => Date.current.strftime("%Y-%m"), "count" => 6 }],
    "daily"    => [{ "_id" => Date.current.strftime("%Y-%m-%d"), "count" => 3 }]
  }.freeze

  test "dashboard resolves every panel from one aggregation" do
    collection = FakeCollection.new(facet: FACET)

    data = with_collection(collection) { Stats.dashboard }

    assert_equal 1, collection.pipelines.length, "exactly one round trip"
    assert collection.pipelines.first.first.key?("$facet"), "and it is a $facet"

    assert_equal 12, data[:total]
    assert_equal({ created: 12, reported: 4, false_positives: 2 }, data[:summary])
    assert_equal 3, data[:new_7d]
    assert_equal "get".upcase, data[:methods].first[:label]
    assert_equal "http", data[:types].first[:key]
    assert_equal "CWE-79", data[:cwes].first[:key]
    assert_equal "xss", data[:tags].first[:key]
    assert_equal 6, data[:timeline].last[:count]
    assert_equal 3, data[:daily].last[:count]
    assert_equal 5, data[:severity].length
  end

  test "dashboard degrades to a fully-zeroed structure when Mongo is unreachable" do
    boom = Object.new.tap { |o| o.define_singleton_method(:aggregate) { |*| raise Mongo::Error.new("down") } }

    data = with_collection(boom) { Stats.dashboard }

    assert_equal 0, data[:total]
    assert_equal 5, data[:severity].length
    assert(data[:severity].all? { |b| b[:count].zero? })
    assert_empty data[:types]
    assert_equal 12, data[:timeline].length
  end
end
