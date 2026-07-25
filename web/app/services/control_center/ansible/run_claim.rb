require "securerandom"
require "digest"

module ControlCenter
  module Ansible
    module RunClaim
      Result = Data.define(:run, :lease, :lease_expires_at, :payload)

      DEFAULT_LEASE_SECONDS = 45
      module_function

      def call(runner:, now: Time.current)
        RunGroup.transaction do
          group = claimable_groups(now).first
          next unless group

          run = group.runs.queued.where("claim_deadline > ?", now).oldest_first.first
          next unless run

          lease = SecureRandom.urlsafe_base64(32)
          lease_expires_at = now + lease_seconds
          run.update!(
            status: "validating",
            runner:,
            lease_digest: Digest::SHA256.hexdigest(lease),
            lease_expires_at:,
            heartbeat_at: now
          )
          group.update!(status: "running", started_at: group.started_at || now)

          Result.new(
            run:,
            lease:,
            lease_expires_at:,
            payload: group.execution_payload.deep_dup
          )
        end
      end

      def claimable_groups(now)
        RunGroup.joins(:runs)
          .where(cancel_requested_at: nil)
          .where.not(execution_payload: nil)
          .where(control_center_ansible_runs: { status: "queued" })
          .where("control_center_ansible_runs.claim_deadline > ?", now)
          .order("control_center_ansible_runs.queued_at ASC, control_center_ansible_runs.id ASC")
          .lock(
            "FOR UPDATE OF control_center_ansible_run_groups, " \
              "control_center_ansible_runs SKIP LOCKED"
          )
      end
      private_class_method :claimable_groups

      def lease_seconds
        Integer(ENV.fetch("ANSIBLE_LEASE_SECONDS", DEFAULT_LEASE_SECONDS.to_s), 10)
      end
      private_class_method :lease_seconds
    end
  end
end
