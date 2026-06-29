require "test_helper"

class NavigationHelperTest < ActionView::TestCase
  include NavigationHelper

  test "true when current controller matches" do
    def controller_name = "bugs"
    assert nav_active?("bugs")
  end

  test "false when current controller does not match" do
    def controller_name = "dashboard"
    assert_not nav_active?("bugs", "stats")
  end
end
