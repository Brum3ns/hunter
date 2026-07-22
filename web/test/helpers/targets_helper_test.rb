require "test_helper"

class TargetsHelperTest < ActionView::TestCase
  include TargetsHelper

  test "renders a brand-colored svg for a known technology" do
    html = tech_icon_tag("php")
    assert_includes html, "<svg"
    assert_includes html, "fill=\"##{SimpleIcons.lookup('php')[:hex]}\""
    assert_includes html, "title=\"PHP\""
    assert html.html_safe?
  end

  test "renders a monogram chip for an unknown technology" do
    html = tech_icon_tag("madeupframeworkxyz")
    refute_includes html, "<svg"
    assert_includes html, "MA"
    assert_includes html, "title=\"madeupframeworkxyz\""
    assert html.html_safe?
  end

  test "COLUMNS lists host first and marks the design's default-visible set" do
    assert_equal "host", TargetsHelper::COLUMNS.first[:key]
    visible = TargetsHelper::COLUMNS.select { |c| c[:default] }.map { |c| c[:key] }
    assert_equal %w[host port ip technologies status title], visible
  end

  test "target_cell_value maps a column key to the target accessor" do
    target = Target.new("target" => { "host" => "a.example.com", "method" => "GET" })
    assert_equal "a.example.com", target_cell_value(target, "host")
    assert_equal "GET", target_cell_value(target, "method")
  end
end
