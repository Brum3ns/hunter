module ControlCenter
  module Ansible
    module RunReaper
      Result = Data.define(:runs, :tasks)

      ACTIVE_RUN_STATUSES = %w[validating running canceling].freeze

      module_function

      def call(now: Time.current)
        Result.new(runs: reap_runs(now), tasks: reap_tasks(now))
      end

      def reap_runs(now)
        reaped = 0
        RunGroup.transaction do
          stale_groups(now).each do |group|
            group_reaped = 0
            stale_group_runs(group, now).each do |run|
              code = run.status == "queued" ? "executor_unavailable" : "executor_lost"
              run.update!(
                status: "failed",
                error_code: code,
                error_detail: code.tr("_", " "),
                lease_digest: nil,
                lease_expires_at: nil,
                heartbeat_at: nil,
                completed_at: now
              )
              reaped += 1
              group_reaped += 1
            end
            if group_reaped.positive?
              group.update!(status: "failed", completed_at: now, execution_payload: nil)
            end
          end
        end
        reaped
      end
      private_class_method :reap_runs

      def stale_run_scope(now)
        Run.where(status: "queued", claim_deadline: ..now)
          .or(Run.where(status: ACTIVE_RUN_STATUSES, lease_expires_at: ..now))
      end
      private_class_method :stale_run_scope

      def stale_groups(now)
        RunGroup.where(id: stale_run_scope(now).select(:run_group_id))
          .order(:id).lock("FOR UPDATE SKIP LOCKED")
      end
      private_class_method :stale_groups

      def stale_group_runs(group, now)
        stale_run_scope(now).where(run_group_id: group.id)
          .order(:id).lock("FOR UPDATE SKIP LOCKED")
      end
      private_class_method :stale_group_runs

      def reap_tasks(now)
        reaped = 0
        ExecutorTask.transaction do
          stale_tasks(now).each do |task|
            code = task.status == "queued" ? "executor_unavailable" : "executor_lost"
            task.update!(
              status: "failed",
              error_code: code,
              error_detail: code.tr("_", " "),
              execution_payload: nil,
              lease_digest: nil,
              lease_expires_at: nil,
              heartbeat_at: nil,
              completed_at: now
            )
            reaped += 1
          end
        end
        reaped
      end
      private_class_method :reap_tasks

      def stale_tasks(now)
        ExecutorTask.where(status: "queued", claim_deadline: ..now)
          .or(ExecutorTask.where(status: "running", lease_expires_at: ..now))
          .order(:id).lock("FOR UPDATE SKIP LOCKED")
      end
      private_class_method :stale_tasks
    end
  end
end
