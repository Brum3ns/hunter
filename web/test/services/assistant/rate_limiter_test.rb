require "test_helper"

class Assistant::RateLimiterTest < ActiveSupport::TestCase
  test "persists atomic minute and hour turn-start windows" do
    now = Time.zone.parse("2026-07-26 12:34:30 UTC")

    with_limits(turn_starts_per_minute: 2, turn_starts_per_hour: 3, max_concurrent_turns: 100) do
      2.times { Assistant::RateLimiter.consume!(user: users(:one), action: "turn_start", now: now) }

      error = assert_raises(Assistant::RateLimiter::LimitExceeded) do
        Assistant::RateLimiter.consume!(user: users(:one), action: "turn_start", now: now)
      end
      assert_equal "turn_rate_minute_exceeded", error.code
      assert_operator error.retry_after_seconds, :>, 0
    end

    buckets = Assistant::RateLimitBucket.where(user: users(:one)).order(:action)
    assert_equal [ "turn_start.hour", "turn_start.minute" ], buckets.pluck(:action)
    assert_equal [ 2, 2 ], buckets.pluck(:count)
  end

  test "persists atomic minute and hour create windows" do
    now = Time.zone.parse("2026-07-26 12:34:30 UTC")

    with_limits(max_creates_per_minute: 2, max_creates_per_hour: 3) do
      2.times { Assistant::RateLimiter.consume!(user: users(:one), action: "create", now: now) }

      error = assert_raises(Assistant::RateLimiter::LimitExceeded) do
        Assistant::RateLimiter.consume!(user: users(:one), action: "create", now: now)
      end
      assert_equal "create_rate_limited", error.code
      assert_operator error.retry_after_seconds, :>, 0
    end

    buckets = Assistant::RateLimitBucket.where(user: users(:one)).order(:action)
    assert_equal [ "create.hour", "create.minute" ], buckets.pluck(:action)
    assert_equal [ 2, 2 ], buckets.pluck(:count)
  end

  test "edit authoring has independent minute and hour windows" do
    now = Time.zone.parse("2026-07-26 12:34:30 UTC")

    with_limits(max_creates_per_minute: 1, max_creates_per_hour: 2) do
      Assistant::RateLimiter.consume!(user: users(:one), action: "edit", now: now)
      error = assert_raises(Assistant::RateLimiter::LimitExceeded) do
        Assistant::RateLimiter.consume!(user: users(:one), action: "edit", now: now)
      end
      assert_equal "authoring_rate_limited", error.code
    end

    assert_equal [ "edit.hour", "edit.minute" ],
      Assistant::RateLimitBucket.where(user: users(:one)).order(:action).pluck(:action)
  end

  test "operational effects enforce per-turn and hourly limits" do
    now = Time.zone.parse("2026-08-19 12:34:30 UTC")
    turn = assistant_turns(:created)

    with_limits(max_effects_per_turn: 2, max_effects_per_hour: 3) do
      2.times do
        Assistant::RateLimiter.consume!(
          user: users(:one), action: "effect:#{turn.id}", now: now
        )
      end
      error = assert_raises(Assistant::RateLimiter::LimitExceeded) do
        Assistant::RateLimiter.consume!(
          user: users(:one), action: "effect:#{turn.id}", now: now
        )
      end

      assert_equal "effect_rate_limited", error.code
    end
  end

  test "launch limits are independent from ordinary effects" do
    now = Time.zone.parse("2026-08-19 12:34:30 UTC")
    turn = assistant_turns(:created)

    with_limits(
      max_effects_per_turn: 10,
      max_effects_per_hour: 10,
      max_launches_per_turn: 1,
      max_launches_per_hour: 2
    ) do
      Assistant::RateLimiter.consume!(
        user: users(:one), action: "effect:#{turn.id}", now: now
      )
      Assistant::RateLimiter.consume!(
        user: users(:one), action: "launch:#{turn.id}", now: now
      )

      error = assert_raises(Assistant::RateLimiter::LimitExceeded) do
        Assistant::RateLimiter.consume!(
          user: users(:one), action: "launch:#{turn.id}", now: now
        )
      end
      assert_equal "effect_rate_limited", error.code
    end
  end

  test "hour limits roll the rejected minute increment back" do
    now = Time.zone.parse("2026-07-26 12:34:30 UTC")

    with_limits(turn_starts_per_minute: 10, turn_starts_per_hour: 1, max_concurrent_turns: 100) do
      Assistant::RateLimiter.consume!(user: users(:one), action: "turn_start", now: now)
      error = assert_raises(Assistant::RateLimiter::LimitExceeded) do
        Assistant::RateLimiter.consume!(user: users(:one), action: "turn_start", now: now)
      end
      assert_equal "turn_rate_hour_exceeded", error.code
    end

    assert_equal 1, Assistant::RateLimitBucket.find_by!(action: "turn_start.minute").count
    assert_equal 1, Assistant::RateLimitBucket.find_by!(action: "turn_start.hour").count
  end

  test "rejects more than the configured number of concurrent turns" do
    now = Time.zone.parse("2026-07-26 12:34:30 UTC")
    Assistant::Turn.create!(
      conversation: assistant_conversations(:one),
      user: users(:one),
      provider_profile: assistant_provider_profiles(:openai),
      status: "running"
    )

    with_limits(turn_starts_per_minute: 10, turn_starts_per_hour: 60, max_concurrent_turns: 2) do
      error = assert_raises(Assistant::RateLimiter::LimitExceeded) do
        Assistant::RateLimiter.consume!(user: users(:one), action: "turn_start", now: now)
      end
      assert_equal "turn_concurrency_exceeded", error.code
    end

    assert_equal 0, Assistant::RateLimitBucket.count
  end

  test "allows only one pending isolated validation per turn" do
    now = Time.zone.parse("2026-07-26 12:34:30 UTC")
    turn = assistant_turns(:created)
    Assistant::Grants::Issuer.call(
      turn: turn, resources: [], tools: [ "validate_ansible_draft" ]
    )
    grant = turn.reload.turn_grant
    Assistant::ValidationRequest.create!(
      turn: turn,
      turn_grant: grant,
      source: "---\n- hosts: workers\n  tasks: []\n",
      expires_at: 1.minute.from_now
    )

    with_limits(max_validations_per_turn: 1) do
      error = assert_raises(Assistant::RateLimiter::LimitExceeded) do
        Assistant::RateLimiter.consume!(
          user: users(:one), action: "validation:#{turn.id}", now: now
        )
      end
      assert_equal "validation_in_flight", error.code
    end
  end

  private

  def with_limits(overrides, &block)
    defaults = {
      turn_starts_per_minute: 10,
      turn_starts_per_hour: 60,
      max_concurrent_turns: 2,
      max_validations_per_turn: 1,
      max_creates_per_minute: 5,
      max_creates_per_hour: 30,
      max_effects_per_turn: 32,
      max_effects_per_hour: 120,
      max_launches_per_turn: 16,
      max_launches_per_hour: 60
    }
    stub_methods(Assistant::Config, defaults.merge(overrides), &block)
  end
end
