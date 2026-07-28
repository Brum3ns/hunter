require "test_helper"

class Assistant::RateLimitBucketTest < ActiveSupport::TestCase
  test "requires a unique bounded user action window" do
    bucket = Assistant::RateLimitBucket.create!(
      user: users(:one),
      action: "turn_start.minute",
      window_started_at: Time.zone.parse("2026-07-26 12:34:00 UTC"),
      count: 1
    )

    duplicate = Assistant::RateLimitBucket.new(
      user: bucket.user,
      action: bucket.action,
      window_started_at: bucket.window_started_at,
      count: 1
    )
    refute duplicate.valid?
    assert_includes duplicate.errors[:window_started_at], "has already been taken"

    bucket.count = -1
    refute bucket.valid?
    assert bucket.errors[:count].any?
  end
end
