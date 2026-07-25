require "securerandom"
require "digest"

module ControlCenter
  module Ansible
    module ExecutorTaskClaim
      Result = Data.define(:task, :lease, :lease_expires_at, :payload)

      DEFAULT_LEASE_SECONDS = 45
      module_function

      def call(runner:, now: Time.current)
        ExecutorTask.transaction do
          task = ExecutorTask.queued.where("claim_deadline > ?", now).oldest_first
            .lock("FOR UPDATE SKIP LOCKED").first
          next unless task

          lease = SecureRandom.urlsafe_base64(32)
          lease_expires_at = now + lease_seconds
          task.update!(
            status: "running",
            runner:,
            lease_digest: Digest::SHA256.hexdigest(lease),
            lease_expires_at:,
            heartbeat_at: now,
            started_at: task.started_at || now
          )
          Result.new(
            task:,
            lease:,
            lease_expires_at:,
            payload: task.execution_payload.deep_dup
          )
        end
      end

      def lease_seconds
        Integer(ENV.fetch("ANSIBLE_LEASE_SECONDS", DEFAULT_LEASE_SECONDS.to_s), 10)
      end
      private_class_method :lease_seconds
    end
  end
end
