# One invocation of the Scope fetch/CLI surface, captured for the Programs "Logs"
# tab. Rows are written by the fetch engine (manual runs from the Config screen,
# scheduled runs from the background job); this model is the read/display side.
# user_id is nullable so scheduled/system runs are not tied to a signed-in user.
class ScopeRun < ApplicationRecord
  belongs_to :user, optional: true

  KINDS = %w[fetch version status check_mongo].freeze
  TRIGGERS = %w[manual scheduled].freeze

  scope :recent, -> { order(started_at: :desc) }
  scope :in_flight, -> { where(finished_at: nil) }

  def in_flight? = finished_at.nil?

  # Shape consumed by the Logs feed (app/javascript/controllers/programs_logs_controller.js).
  def as_log_json
    {
      id: id,
      kind: kind,
      platform: platform,
      trigger: trigger,
      mode: mode,
      bug_bounty: bug_bounty,
      vdp: vdp,
      programs: programs,
      success: success,
      in_flight: in_flight?,
      exit_status: exit_status,
      duration_ms: duration_ms,
      stdout_bytes: stdout_bytes,
      stdout_excerpt: stdout_excerpt,
      stderr_excerpt: stderr_excerpt,
      error_class: error_class,
      started_at: started_at&.iso8601,
      finished_at: finished_at&.iso8601,
      user: user&.username
    }
  end
end
