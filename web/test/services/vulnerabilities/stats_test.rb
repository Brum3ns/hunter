require "test_helper"

class Vulnerabilities::StatsTest < ActiveSupport::TestCase
  # Records each count_documents filter and returns a scripted count per call.
  class FakeCollection
    attr_reader :filters

    def initialize(counts) = (@counts = counts; @filters = [])
    def count_documents(filter)
      @filters << filter
      @counts.shift
    end
  end

  test "summary maps counts to the created/reported/false-positive cards" do
    collection = FakeCollection.new([12, 4, 2])

    stub_methods(Vulnerabilities::Stats, collection: collection) do
      result = Vulnerabilities::Stats.summary

      assert_equal({ created: 12, reported: 4, false_positives: 2 }, result)
    end

    assert_equal({}, collection.filters[0])
    assert_equal({ "report.status" => { "$in" => %w[reported] } }, collection.filters[1])
    assert_equal({ "report.status" => { "$in" => %w[false_positive fp] } }, collection.filters[2])
  end

  test "summary returns zeros when Mongo is unreachable" do
    boom = ->(*) { raise Mongo::Error.new("down") }

    stub_methods(Vulnerabilities::Stats, count: boom) do
      assert_equal({ created: 0, reported: 0, false_positives: 0 }, Vulnerabilities::Stats.summary)
    end
  end
end
