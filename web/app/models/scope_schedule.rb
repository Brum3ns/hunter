# Per-user recurring-fetch schedule for the Scope tooling. Read/written from the
# Settings area; consumed by the (deferred) scheduler engine, which fetches the
# enabled platforms every interval_minutes.
class ScopeSchedule < ApplicationRecord
  belongs_to :user

  MIN_INTERVAL = 5
  MAX_INTERVAL = 1440
  MODES = %w[public private all].freeze

  validates :interval_minutes,
            numericality: { only_integer: true, greater_than_or_equal_to: MIN_INTERVAL, less_than_or_equal_to: MAX_INTERVAL }
  validates :mode, inclusion: { in: MODES }
  validate :platforms_known
  validate :bounty_vdp_exclusive

  # Only platforms we recognise, in canonical order.
  def enabled_platforms
    ScopePlatforms::ALL & Array(platforms)
  end

  def due?(now = Time.current)
    enabled? && next_run_at.present? && next_run_at <= now
  end

  # next run = last run (or now) + interval, never in the past.
  def recompute_next_run_at!
    base = last_run_at || Time.current
    self.next_run_at = [base + interval_minutes.minutes, Time.current].max
  end

  private

  def platforms_known
    unknown = Array(platforms) - ScopePlatforms::ALL
    errors.add(:platforms, "contains unknown platforms: #{unknown.join(', ')}") if unknown.any?
  end

  def bounty_vdp_exclusive
    errors.add(:base, "choose bug-bounty or VDP, not both") if bug_bounty? && vdp?
  end
end
