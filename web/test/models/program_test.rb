require "test_helper"

class ProgramTest < ActiveSupport::TestCase
  test "bounty_range for a range" do
    p = Program.new("bounty" => true, "bounty_min" => 100, "bounty_max" => 5000, "currency" => "USD")
    assert_equal "$100 – $5,000", p.bounty_range
  end

  test "bounty_range for VDP" do
    assert_equal "No bounty", Program.new("bounty" => false).bounty_range
  end

  test "name falls back to a titleized slug" do
    assert_equal "Acme Corp", Program.new("slug" => "acme-corp").name
  end

  test "to_param is the sid" do
    assert_equal "abc", Program.new("_sid" => "abc").to_param
  end
end
