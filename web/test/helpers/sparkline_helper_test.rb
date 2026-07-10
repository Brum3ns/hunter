require "test_helper"

class SparklineHelperTest < ActionView::TestCase
  include SparklineHelper

  test "renders an inline svg polyline for a series" do
    html = sparkline([1, 5, 2, 8])

    assert_includes html, "<svg"
    assert_includes html, "<polyline"
  end

  test "returns nil for an empty series" do
    assert_nil sparkline([])
    assert_nil sparkline(nil)
  end
end
