# A single detected change to a bug-bounty program, powering the Programs
# "Monitor" tab's live feed. Per-user: each operator monitors their own set of
# programs, so the feed is always scoped to Current.user. Rows are produced by
# the change-detector engine; this model is the read/display side.
class ProgramChange < ApplicationRecord
  belongs_to :user
  belongs_to :scope_run, optional: true

  KINDS = %w[
    program_added program_removed
    bounty_changed status_changed
    scope_added scope_removed
    outofscope_added outofscope_removed
  ].freeze

  scope :recent, -> { order(detected_at: :desc) }

  # Shape consumed by the Monitor feed (app/javascript/controllers/programs_monitor_controller.js).
  def as_feed_json
    {
      id: id,
      platform: platform,
      program_sid: program_sid,
      program_name: program_name,
      kind: kind,
      old_value: old_value,
      new_value: new_value,
      detected_at: detected_at&.iso8601,
      scope_run_id: scope_run_id
    }
  end
end
