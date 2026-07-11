require "test_helper"

class Programs::TabsTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }

  test "monitor and logs redirect an unauthenticated visitor to sign in" do
    get programs_monitor_path
    assert_redirected_to new_session_path
    get programs_logs_path
    assert_redirected_to new_session_path
  end

  test "monitor page renders with the Monitor tab active" do
    sign_in_as(@user)
    get programs_monitor_path
    assert_response :success
    assert_select "a[href=?][aria-current=page]", programs_monitor_path, text: "Monitor"
    assert_select "a[href=?]:not([aria-current])", programs_root_path, text: "Programs"
    assert_select "a[href=?]", programs_logs_path, text: "Logs"
    # Feed mount point wired to the changes API.
    assert_select "section[data-controller=programs-monitor][data-programs-monitor-url-value=?]",
                  api_v1_programs_changes_path
  end

  test "logs page renders with the Logs tab active" do
    sign_in_as(@user)
    get programs_logs_path
    assert_response :success
    assert_select "a[href=?][aria-current=page]", programs_logs_path, text: "Logs"
    assert_select "section[data-controller=programs-logs][data-programs-logs-url-value=?]",
                  api_v1_programs_runs_path
  end
end
