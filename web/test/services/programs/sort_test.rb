require "test_helper"

class Programs::SortTest < ActiveSupport::TestCase
  def prog(sid, name) = Program.new("_sid" => sid, "name" => name)

  test "name sort ascending is case-insensitive" do
    a = prog("1", "beta"); b = prog("2", "Alpha")
    assert_equal %w[2 1], Programs::Sort.call([a, b], "name", "asc").map(&:sid)
  end

  test "resolve_dir falls back to the option default" do
    assert_equal "asc",  Programs::Sort.resolve_dir("name", nil)
    assert_equal "desc", Programs::Sort.resolve_dir("bounty_max", nil)
  end
end
