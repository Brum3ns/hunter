require "test_helper"

class SidebarShellTest < ActionDispatch::IntegrationTest
  setup { sign_in_as(User.take) }

  test "layout includes the importmap module script" do
    get root_path
    assert_select "script[type=importmap]", count: 1
  end

  test "renders the sidebar with all nav links" do
    get root_path
    assert_select "[data-controller=sidebar] aside[data-sidebar-target=aside]", count: 1
    assert_select "a[href=?]", root_path
    assert_select "a[href=?]", programs_root_path
    assert_select "a[href=?]", vulnerabilities_root_path
    assert_select "a[href=?]", control_center_root_path
    assert_select "a[href=?]", cves_path
    assert_select "a[href=?]", settings_path
    assert_select "a[href=?]", help_path
  end

  test "highlights the active section" do
    get vulnerabilities_root_path
    assert_select "a[href=?][aria-current=page]", vulnerabilities_root_path
    assert_select "a[href=?]:not([aria-current])", programs_root_path
  end

  test "renders folded width when the cookie is set" do
    cookies[:sidebar_folded] = "1"
    get root_path
    assert_select "aside[data-sidebar-target=aside][class*=?]", "md:w-12"
  end

  test "renders unfolded width by default" do
    get root_path
    assert_select "aside[data-sidebar-target=aside][class*=?]", "md:w-44"
  end
end
