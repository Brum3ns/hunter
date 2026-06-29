require "test_helper"

class SidebarShellTest < ActionDispatch::IntegrationTest
  setup { sign_in_as(User.take) }

  test "layout includes the importmap module script" do
    get root_path
    assert_response :success
    assert_select "script[type=importmap]", count: 1
  end
end
