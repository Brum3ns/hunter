require "test_helper"

class SidebarShellTest < ActionDispatch::IntegrationTest
  setup { sign_in_as(User.take) }

  test "layout includes the importmap module script" do
    get root_path
    assert_select "script[type=importmap]", count: 1
  end

  test "renders the sidebar with all nav links" do
    get root_path
    assert_select "aside[data-controller=sidebar]", count: 1
    assert_select "a[href=?]", root_path
    assert_select "a[href=?]", bugs_path
    assert_select "a[href=?]", stats_path
    assert_select "a[href=?]", account_path
    assert_select "a[href=?]", settings_path
    assert_select "a[href=?]", notifications_path
  end

  test "highlights the active section" do
    get bugs_path
    assert_select "a[href=?][aria-current=page]", bugs_path
    assert_select "a[href=?]:not([aria-current])", stats_path
  end

  test "renders folded width when the cookie is set" do
    cookies[:sidebar_folded] = "1"
    get root_path
    assert_select "aside[data-controller=sidebar][class*=?]", "md:w-16"
  end

  test "renders unfolded width by default" do
    get root_path
    assert_select "aside[data-controller=sidebar][class*=?]", "md:w-60"
  end
end
