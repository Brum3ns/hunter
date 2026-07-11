require "test_helper"

class ControlCenter::TabsTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }

  test "templates and jobs redirect an unauthenticated visitor to sign in" do
    get control_center_root_path
    assert_redirected_to new_session_path
    get control_center_jobs_path
    assert_redirected_to new_session_path
  end

  test "templates page renders with the Templates tab active" do
    sign_in_as(@user)
    get control_center_root_path
    assert_response :success
    assert_select "a[href=?][aria-current=page]", control_center_root_path, text: "Templates"
    assert_select "a[href=?]:not([aria-current])", control_center_jobs_path, text: "Jobs"
  end

  test "jobs page renders with the Jobs tab active" do
    sign_in_as(@user)
    get control_center_jobs_path
    assert_response :success
    assert_select "a[href=?][aria-current=page]", control_center_jobs_path, text: "Jobs"
  end

  test "templates page mounts the health badge wired to the health API" do
    sign_in_as(@user)
    get control_center_root_path
    assert_select "[data-controller~=control-center-health][data-control-center-health-url-value=?]",
                  api_v1_control_center_health_path
  end

  test "jobs page mounts the health badge" do
    sign_in_as(@user)
    get control_center_jobs_path
    assert_select "[data-controller~=control-center-health]"
  end
end
