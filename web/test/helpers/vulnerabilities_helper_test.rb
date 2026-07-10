require "test_helper"

class VulnerabilitiesHelperTest < ActionView::TestCase
  test "severity_badge_classes returns colored classes per severity" do
    assert_includes severity_badge_classes("critical"), "bg-red-100"
    assert_includes severity_badge_classes("high"),     "bg-orange-100"
    assert_includes severity_badge_classes("medium"),   "bg-amber-100"
    assert_includes severity_badge_classes("low"),      "bg-blue-100"
    assert_includes severity_badge_classes("info"),     "bg-zinc-200"
  end

  test "severity_badge_classes carries dark-mode variants" do
    assert_includes severity_badge_classes("critical"), "dark:bg-red-950"
    assert_includes severity_badge_classes("high"),     "dark:bg-orange-950"
  end

  test "severity_badge_classes falls back to info for unknown severity" do
    assert_equal severity_badge_classes("info"), severity_badge_classes("nonsense")
  end

  test "STATUSES is the new five-value vocabulary" do
    assert_equal %w[new triage reported close false_positive], VulnerabilitiesHelper::STATUSES
  end

  test "display_status passes known statuses through" do
    %w[new triage reported close false_positive].each do |s|
      assert_equal s, display_status(s)
    end
  end

  test "display_status defaults blank and legacy values to new" do
    assert_equal "new", display_status("unreviewed")
    assert_equal "new", display_status("")
    assert_equal "new", display_status(nil)
  end

  test "status_select_options humanizes each status" do
    assert_includes status_select_options, ["False positive", "false_positive"]
    assert_includes status_select_options, ["New", "new"]
  end
end
