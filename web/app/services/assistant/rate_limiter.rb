module Assistant
  module RateLimiter
    class LimitExceeded < StandardError
      attr_reader :code, :retry_after_seconds

      def initialize(code, retry_after_seconds: 1)
        @code = code
        @retry_after_seconds = [ retry_after_seconds.to_i, 1 ].max
        super(code)
      end
    end

    module_function

    def consume!(user:, action:, now: Time.current)
      raise ArgumentError, "user is required" unless user

      Assistant::RateLimitBucket.transaction do
        user.lock!
        Assistant::RateLimitBucket.where(user: user)
          .where("window_started_at < ?", now.in_time_zone - 2.hours).delete_all
        case action.to_s
        when "turn_start" then consume_turn_start!(user, now.in_time_zone)
        when /\Avalidation:(\d+)\z/ then check_validation!(user, Regexp.last_match(1), now.in_time_zone)
        else raise ArgumentError, "unsupported assistant rate-limit action"
        end
      end
      true
    end

    def consume_turn_start!(user, now)
      active = Assistant::Turn.where(user: user)
        .where.not(status: Assistant::Turn::TERMINAL_STATUSES).count
      if active >= Assistant::Config.max_concurrent_turns
        raise LimitExceeded, "turn_concurrency_exceeded"
      end

      consume_window!(
        user: user,
        action: "turn_start.minute",
        started_at: now.change(sec: 0),
        limit: Assistant::Config.turn_starts_per_minute,
        code: "turn_rate_minute_exceeded",
        retry_after: ->(start) { (start + 1.minute - now).ceil }
      )
      consume_window!(
        user: user,
        action: "turn_start.hour",
        started_at: now.change(min: 0, sec: 0),
        limit: Assistant::Config.turn_starts_per_hour,
        code: "turn_rate_hour_exceeded",
        retry_after: ->(start) { (start + 1.hour - now).ceil }
      )
    end
    private_class_method :consume_turn_start!

    def consume_window!(user:, action:, started_at:, limit:, code:, retry_after:)
      bucket = Assistant::RateLimitBucket.find_or_initialize_by(
        user: user, action: action, window_started_at: started_at
      )
      if bucket.count >= limit
        raise LimitExceeded.new(code, retry_after_seconds: retry_after.call(started_at))
      end

      bucket.count += 1
      bucket.save!
    end
    private_class_method :consume_window!

    def check_validation!(user, turn_id, now)
      turn = Assistant::Turn.where(user: user).lock.find_by(id: turn_id)
      raise ArgumentError, "validation turn is unavailable" unless turn

      pending = Assistant::ValidationRequest.where(turn: turn, status: "pending")
        .where("expires_at > ?", now).count
      if pending >= Assistant::Config.max_validations_per_turn
        raise LimitExceeded, "validation_in_flight"
      end
    end
    private_class_method :check_validation!
  end
end
