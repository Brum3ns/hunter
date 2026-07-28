require "digest"

module ControlCenter
  module Ansible
    module LeaseVerifier
      class Conflict < StandardError
        attr_reader :code

        def initialize(message = "lease is invalid or expired", code: "lease_conflict")
          @code = code
          super(message)
        end
      end

      module_function

      def verify!(record, runner:, lease:, statuses:, now: Time.current)
        reject! unless record.runner_id == runner.id
        reject! unless Array(statuses).include?(record.status)
        reject! unless record.lease_expires_at && record.lease_expires_at > now

        submitted_digest = Digest::SHA256.hexdigest(lease.to_s)
        stored_digest = record.lease_digest.to_s
        reject! unless stored_digest.bytesize == submitted_digest.bytesize
        reject! unless ActiveSupport::SecurityUtils.secure_compare(stored_digest, submitted_digest)

        record
      end

      def reject!
        raise Conflict
      end
      private_class_method :reject!
    end
  end
end
