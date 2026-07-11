# Per-user MongoDB monitor settings for the Scope tooling. Read/written from the
# Settings area; consumed by the (deferred) monitor engine, which diffs the
# enabled platforms' programs every interval_seconds (floored to the tick rate).
class MonitorConfig < ApplicationRecord
  belongs_to :user

  MIN_INTERVAL = 5
  MAX_INTERVAL = 86_400

  validates :interval_seconds,
            numericality: { only_integer: true, greater_than_or_equal_to: MIN_INTERVAL, less_than_or_equal_to: MAX_INTERVAL }
  validate :platforms_known

  def enabled_platforms
    ScopePlatforms::ALL & Array(platforms)
  end

  def due?(now = Time.current)
    enabled? && next_tick_at.present? && next_tick_at <= now
  end

  def recompute_next_tick_at!
    base = last_tick_at || Time.current
    self.next_tick_at = [base + interval_seconds.seconds, Time.current].max
  end

  private

  def platforms_known
    unknown = Array(platforms) - ScopePlatforms::ALL
    errors.add(:platforms, "contains unknown platforms: #{unknown.join(', ')}") if unknown.any?
  end
end
