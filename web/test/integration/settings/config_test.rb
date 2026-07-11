require "test_helper"

class Settings::ConfigTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }

  test "settings page shows all organized sections" do
    sign_in_as(@user)
    get settings_path
    assert_response :success
    assert_select "section#runners h2", text: "Runners"
    assert_select "section#credentials h2", text: "Platform credentials"
    assert_select "section#schedule h2", text: "Fetch schedule"
    assert_select "section#monitor h2", text: "Monitor"
  end

  test "saving the fetch schedule creates the per-user record" do
    sign_in_as(@user)
    patch settings_schedule_path, params: {
      scope_schedule: { enabled: "1", interval_minutes: "30", mode: "public",
                        bug_bounty: "1", vdp: "0", platforms: ["", "hackerone", "bugcrowd"] }
    }
    assert_redirected_to settings_path(anchor: "schedule")

    schedule = @user.reload.scope_schedule
    assert schedule.enabled?
    assert_equal 30, schedule.interval_minutes
    assert_equal %w[hackerone bugcrowd], schedule.enabled_platforms
    assert schedule.next_run_at.present?
  end

  test "an invalid schedule is rejected with an alert and saves nothing" do
    sign_in_as(@user)
    patch settings_schedule_path, params: {
      scope_schedule: { enabled: "1", interval_minutes: "1", mode: "all", platforms: [""] }
    }
    assert_redirected_to settings_path(anchor: "schedule")
    assert_nil @user.reload.scope_schedule
  end

  test "saving the monitor config creates the per-user record" do
    sign_in_as(@user)
    patch settings_monitor_config_path, params: {
      monitor_config: { enabled: "1", interval_seconds: "600", platforms: ["", "intigriti"] }
    }
    assert_redirected_to settings_path(anchor: "monitor")

    config = @user.reload.monitor_config
    assert config.enabled?
    assert_equal 600, config.interval_seconds
    assert_equal %w[intigriti], config.enabled_platforms
  end
end
