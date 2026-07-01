# A unit of work executed by a Runner. `queued -> running -> succeeded|failed`;
# a job can also fail directly from queued at enqueue-time validation. The claim
# is atomic and scoped to the runner's kinds, so a runner is structurally unable
# to observe jobs outside its allowlist.
class RunnerJob < ApplicationRecord
  KINDS = %w[curl].freeze
  STATUSES = %w[queued running succeeded failed].freeze

  # A running job older than this is presumed dead (runner crash / lost result).
  TTL_SECONDS = Integer(ENV.fetch("RUNNER_JOB_TTL", 90))

  belongs_to :requested_by, class_name: "User"
  belongs_to :runner, optional: true

  validates :kind, inclusion: { in: KINDS }
  validates :command, presence: true
  validates :vulnerability_id, presence: true
  validates :status, inclusion: { in: STATUSES }

  def self.claim!(runner)
    kinds = Array(runner.kinds)
    return nil if kinds.empty?

    row = connection.exec_query(<<~SQL, "RunnerJob Claim", [runner.id, kinds.to_s.gsub(/\A\[|\]\z/, "")], prepare: false).first
      UPDATE runner_jobs SET status = 'running', runner_id = $1, claimed_at = now(), started_at = now(), updated_at = now()
      WHERE id = (
        SELECT id FROM runner_jobs
        WHERE status = 'queued' AND kind = ANY(string_to_array($2, ','))
        ORDER BY created_at
        FOR UPDATE SKIP LOCKED
        LIMIT 1
      )
      RETURNING id
    SQL

    row && find(row["id"])
  end

  def record_result!(exit_status:, stdout:, stderr:, error:, duration_ms:, output_truncated:)
    succeeded = error.blank? && exit_status.to_i.zero?
    update!(
      status: succeeded ? "succeeded" : "failed",
      exit_status: exit_status,
      stdout: stdout,
      stderr: stderr,
      error: error,
      duration_ms: duration_ms,
      output_truncated: !!output_truncated,
      finished_at: Time.current
    )
  end

  def reap_if_stale!
    return false unless status == "running"
    return false unless started_at && started_at < TTL_SECONDS.seconds.ago

    update!(status: "failed", error: "runner timed out", finished_at: Time.current)
    true
  end

  def self.reap_stale!
    where(status: "running").where(started_at: ..TTL_SECONDS.seconds.ago)
      .update_all(status: "failed", error: "runner timed out", finished_at: Time.current)
  end

  def terminal?
    status == "succeeded" || status == "failed"
  end
end
