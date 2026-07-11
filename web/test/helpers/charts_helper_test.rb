require "test_helper"

class ChartsHelperTest < ActionView::TestCase
  test "donut_segments returns [] when every count is zero" do
    assert_empty donut_segments([{ label: "a", count: 0 }, { label: "b", count: 0 }])
  end

  test "donut_segments drops zero-count entries" do
    result = donut_segments([{ label: "a", count: 3 }, { label: "b", count: 0 }])
    assert_equal %w[a], result.map { |s| s[:label] }
  end

  test "donut_segments computes percentages that sum to 100" do
    result = donut_segments([{ label: "a", count: 1 }, { label: "b", count: 3 }])
    assert_in_delta 25.0, result[0][:percent], 0.001
    assert_in_delta 75.0, result[1][:percent], 0.001
    assert_in_delta 100.0, result.sum { |s| s[:percent] }, 0.001
  end

  test "donut_segments seams the first arc at 12 o'clock and abuts the rest" do
    result = donut_segments([{ label: "a", count: 1 }, { label: "b", count: 3 }])

    # First segment starts at the top; dasharray encodes "percent gap".
    assert_in_delta 25.0, result[0][:dashoffset], 0.001
    assert_equal "25.0 75.0", result[0][:dasharray]
    # Second segment begins where the first ended: (125 - 25) % 100 == 0.
    assert_in_delta 0.0, result[1][:dashoffset], 0.001
  end

  test "donut_segments carries the color class through untouched" do
    result = donut_segments([{ label: "a", count: 1, color: "text-red-500" }])
    assert_equal "text-red-500", result[0][:color]
  end
end
