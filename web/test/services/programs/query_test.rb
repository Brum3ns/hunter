require "test_helper"

class Programs::QueryTest < ActiveSupport::TestCase
  def prog(sid, **attrs) = Program.new({ "_sid" => sid }.merge(attrs.transform_keys(&:to_s)))

  test "falls back to in-memory filter/sort when mongo is unusable" do
    programs = [prog("1", platform: "hackerone", name: "Beta"),
                prog("2", platform: "bugcrowd",  name: "Alpha")]
    stub_methods(Programs::MongoSource, healthy?: -> { false }) do
      stub_methods(Programs::Source, all: -> { programs }) do
        result = Programs::Query.call({ sort: "name", dir: "asc" }.with_indifferent_access)
        assert_equal %w[2 1], result.programs.map(&:sid)
        assert_equal 2, result.total
      end
    end
  end
end
