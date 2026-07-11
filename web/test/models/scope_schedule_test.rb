require "test_helper"

class ScopeScheduleTest < ActiveSupport::TestCase
  setup { @user = users(:one) }

  def build(**attrs)
    @user.build_scope_schedule({ interval_minutes: 60, mode: "all" }.merge(attrs))
  end

  test "rejects an out-of-range interval" do
    assert_not build(interval_minutes: 1).valid?
    assert_not build(interval_minutes: 99999).valid?
    assert build(interval_minutes: 60).valid?
  end

  test "rejects an unknown mode and unknown platforms" do
    assert_not build(mode: "bogus").valid?
    assert_not build(platforms: %w[hackerone martians]).valid?
    assert build(platforms: %w[hackerone bugcrowd]).valid?
  end

  test "bug_bounty and vdp are mutually exclusive" do
    assert_not build(bug_bounty: true, vdp: true).valid?
    assert build(bug_bounty: true, vdp: false).valid?
  end

  test "enabled_platforms keeps only known platforms in canonical order" do
    schedule = build(platforms: %w[bugcrowd martians hackerone])
    assert_equal %w[hackerone bugcrowd], schedule.enabled_platforms
  end

  test "recompute_next_run_at! never schedules in the past" do
    schedule = build(last_run_at: 10.hours.ago, interval_minutes: 60)
    schedule.recompute_next_run_at!
    assert_operator schedule.next_run_at, :>=, Time.current - 1.second
  end
end
