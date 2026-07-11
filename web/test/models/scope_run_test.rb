require "test_helper"

class ScopeRunTest < ActiveSupport::TestCase
  test "in_flight? is true until finished_at is set" do
    run = ScopeRun.new(kind: "fetch", started_at: Time.current)
    assert run.in_flight?
    run.finished_at = Time.current
    assert_not run.in_flight?
  end

  test "recent orders newest-started first" do
    old = ScopeRun.create!(kind: "fetch", started_at: 2.hours.ago)
    new = ScopeRun.create!(kind: "fetch", started_at: 1.minute.ago)
    assert_equal [new.id, old.id], ScopeRun.recent.pluck(:id)
  end

  test "as_log_json exposes the display fields and flattens the user" do
    user = users(:one)
    run = ScopeRun.create!(kind: "fetch", platform: "hackerone", user: user,
                           started_at: Time.current, finished_at: Time.current, success: true, duration_ms: 42)
    json = run.as_log_json
    assert_equal "hackerone", json[:platform]
    assert_equal user.username, json[:user]
    assert_equal false, json[:in_flight]
    assert json[:started_at].is_a?(String), "timestamps serialize as iso8601 strings"
  end
end
