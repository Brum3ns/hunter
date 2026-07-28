module ControlCenter
  # Audit + status record for one job submission. template_snapshot freezes the
  # rendered template at submit time so history survives later template edits.
  class Job < ApplicationRecord
    self.table_name = "control_center_jobs"

    # queued -> running -> succeeded|failed. `pending` retained so historical
    # rows still validate; new submissions start `queued`.
    STATUSES = %w[queued running succeeded failed pending].freeze

    validates :template_name, presence: true
    validates :status, inclusion: { in: STATUSES }
  end
end
