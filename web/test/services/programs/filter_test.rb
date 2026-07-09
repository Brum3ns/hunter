require "test_helper"

class Programs::FilterTest < ActiveSupport::TestCase
  def prog(attrs) = Program.new(attrs)

  test "by platform" do
    h1 = prog("_sid" => "1", "platform" => "hackerone")
    bc = prog("_sid" => "2", "platform" => "bugcrowd")
    out = Programs::Filter.call([h1, bc], { platforms: ["hackerone"] }.with_indifferent_access)
    assert_equal %w[1], out.map(&:sid)
  end

  test "by bounty with" do
    a = prog("_sid" => "1", "bounty" => true)
    b = prog("_sid" => "2", "bounty" => false)
    out = Programs::Filter.call([a, b], { bounty: "with" }.with_indifferent_access)
    assert_equal %w[1], out.map(&:sid)
  end
end
